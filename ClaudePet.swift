// Claude Pet, a floating Pokémon for every Claude or Codex agent you're running.
//
// Status comes from herdr (`herdr agent list`) when it's running, and from
// Claude Code hooks (`ClaudePet --hook`, added by install.sh) for sessions
// outside herdr:
//   blocked → hops and flashes red, like it's taking hits
//   done    → jumps for joy over "<Pokémon> is done" (until you view the agent)
//   working → walks back and forth over a row of dots
//   idle    → steps in place, falls asleep (z's) after a quiet spell, and
//             goes back in its Poké Ball after 12 hours
// Only a pet off the ground casts a shadow.
//
// Each agent keeps its Pokémon (by herdr pane or session). Click a pet to jump to its
// agent, drag it anywhere, right-click to change Pokémon or line them up.
// Sprites come from fetch-sprites.sh. `ClaudePet --render <png>` writes a
// sheet of every mood and the whole roster, for checking without a screen.

import AppKit
import ApplicationServices
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Roster and sprites

struct PokemonSpecies {
    let id: Int
    let slug: String

    var assetName: String { slug.replacingOccurrences(of: "-", with: "_") }
    var displayName: String {
        switch slug {
        case "nidoran-f": return "Nidoran♀"
        case "nidoran-m": return "Nidoran♂"
        case "farfetchd": return "Farfetch’d"
        case "mr-mime": return "Mr. Mime"
        case "mime-jr": return "Mime Jr."
        case "ho-oh": return "Ho-Oh"
        case "porygon-z": return "Porygon-Z"
        default: return slug.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
        }
    }
}

enum PokemonCatalog {
    struct Response: Decodable {
        struct Entry: Decodable { let name: String }
        let results: [Entry]
    }

    static let fallback = [
    "bulbasaur", "charmander", "squirtle", "pikachu", "oddish", "psyduck", "poliwag", "abra",
    "geodude", "slowpoke", "gastly", "gengar", "cubone", "magikarp", "gyarados", "lapras", "ditto",
    "eevee", "vaporeon", "jolteon", "flareon", "espeon", "umbreon", "leafeon", "glaceon", "sylveon",
    "kabuto", "snorlax", "articuno", "zapdos", "moltres", "dragonite", "sentret", "wooper", "quagsire",
    ]
    static let catalogPath = NSHomeDirectory() + "/.local/share/claude-pet/pokemon.json"
    static let species: [PokemonSpecies] = {
        guard let data = FileManager.default.contents(atPath: catalogPath),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.results.count >= 649 else {
            return fallback.enumerated().map { PokemonSpecies(id: $0.offset + 1, slug: $0.element) }
        }
        return response.results.prefix(649).enumerated().map { PokemonSpecies(id: $0.offset + 1, slug: $0.element.name) }
    }()
    static let generations: [(title: String, range: ClosedRange<Int>)] = [
        ("Generation I · Kanto", 1...151),
        ("Generation II · Johto", 152...251),
        ("Generation III · Hoenn", 252...386),
        ("Generation IV · Sinnoh", 387...493),
        ("Generation V · Unova", 494...649),
    ]
    static func names(in range: ClosedRange<Int>) -> [String] {
        species.filter { range.contains($0.id) }.map(\.assetName)
    }
    static func displayName(for assetName: String) -> String {
        species.first { $0.assetName == assetName }?.displayName ?? assetName.capitalized
    }
}

let roster = PokemonCatalog.species.map(\.assetName)

enum SpritePalette {
    static func colors(in path: String) -> [UInt8]? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 3, lines[0] == "JASC-PAL", lines[1] == "0100",
              let count = Int(lines[2]), (1...256).contains(count), lines.count == count + 3 else { return nil }
        var colors: [UInt8] = []
        for line in lines.dropFirst(3) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            let channels = fields.compactMap { UInt8($0) }
            guard fields.count == 3, channels.count == 3 else { return nil }
            colors.append(contentsOf: channels)
        }
        return colors
    }
}

/// One roll per appearance, saved so app restarts do not reroll a visible pet.
enum ShinyEncounters {
    static let denominator = 25
    static let key = "pokemonAppearances.v1"

    static func resolve(pane: String, pokemon: String, reroll: Bool = false,
                        defaults: UserDefaults = .standard,
                        roll: () -> Int = { Int.random(in: 0..<denominator) }) -> Bool {
        if !reroll, let saved = defaults.dictionary(forKey: key)?[pane] as? [String: Any],
           saved["pokemon"] as? String == pokemon, let shiny = saved["shiny"] as? Bool { return shiny }
        let shiny = roll() == 0
        save(shiny, pane: pane, pokemon: pokemon, defaults: defaults)
        return shiny
    }

    static func save(_ shiny: Bool, pane: String, pokemon: String, defaults: UserDefaults = .standard) {
        var saved = defaults.dictionary(forKey: key) ?? [:]
        saved[pane] = ["pokemon": pokemon, "shiny": shiny]
        defaults.set(saved, forKey: key)
    }
}

/// A follower sheet: square frames for down ×2, up ×2, left ×2, and
/// optionally right ×2 (otherwise left is mirrored).
struct SpriteSheet {
    let frames: [CGImage]
    /// The highest row any frame draws in, for stacking pets in a column by their real height.
    let top: Int
    /// The farthest any frame reaches from its centre column, for spacing pets in a row.
    let halfWidth: Int
    /// Each frame's visible pixels, from its leftmost to rightmost and topmost
    /// to bottommost, in pixels from the frame's top-left corner.
    let boxes: [CGRect]

    static let directory = NSHomeDirectory() + "/.local/share/claude-pet/sprites"
    static var cache: [String: SpriteSheet] = [:]

    static func named(_ name: String, shiny: Bool = false) -> SpriteSheet? {
        let key = name + (shiny ? ":shiny" : ":normal")
        if let cached = cache[key] { return cached }
        let palettePath = "\(directory)/palettes/\(name)_\(shiny ? "shiny" : "normal").pal"
        guard let palette = SpritePalette.colors(in: palettePath),
              let frames = frames(in: "\(directory)/\(name).png", palette: palette), frames.count >= 6 else { return nil }
        let boxes = frames.map(visibleBox)
        let extents = zip(frames, boxes).map { frame, box -> (top: Int, halfWidth: Int) in
            let half = frame.width / 2
            return box.isEmpty ? (frame.height, 0) : (Int(box.minY), max(half - Int(box.minX), Int(box.maxX) - half))
        }
        let sheet = SpriteSheet(frames: frames, top: extents.map(\.top).min() ?? 0,
                                halfWidth: extents.map(\.halfWidth).max() ?? 0, boxes: boxes)
        cache[key] = sheet
        return sheet
    }

    /// The smallest rectangle holding all of an image's visible pixels, in
    /// pixels from its top-left corner (empty if it has none).
    static func visibleBox(of image: CGImage) -> CGRect {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = { context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                             return context.data?.assumingMemoryBound(to: UInt8.self) }()
        else { return CGRect(x: 0, y: 0, width: w, height: h) }
        var top = h, bottom = -1, first = w, last = -1
        for row in 0..<h {
            for x in 0..<w where pixels[(row * w + x) * 4 + 3] > 0 {
                top = min(top, row)
                bottom = max(bottom, row)
                first = min(first, x)
                last = max(last, x)
            }
        }
        guard last >= 0 else { return .zero }
        return CGRect(x: first, y: top, width: last + 1 - first, height: bottom + 1 - top)
    }

    /// Decodes a row of square frames and makes the background (palette entry 0) transparent.
    static func frames(in path: String, palette: [UInt8]? = nil) -> [CGImage]? {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let colored: CGImage
        if let palette {
            guard (3...768).contains(palette.count), palette.count.isMultiple(of: 3),
                  image.colorSpace?.model == .indexed,
                  let indexed = CGColorSpace(indexedBaseSpace: space, last: palette.count / 3 - 1, colorTable: palette),
                  let provider = image.dataProvider,
                  let replacement = CGImage(width: image.width, height: image.height,
                                            bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel,
                                            bytesPerRow: image.bytesPerRow, space: indexed, bitmapInfo: image.bitmapInfo,
                                            provider: provider, decode: nil, shouldInterpolate: false,
                                            intent: .defaultIntent) else { return nil }
            colored = replacement
        } else {
            colored = image
        }
        context.draw(colored, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        let background = palette.map { (r: $0[0], g: $0[1], b: $0[2]) } ?? backgroundColor(in: data)
        let bits = image.bitsPerPixel
        let indexedData = image.colorSpace?.model == .indexed && [1, 2, 4, 8].contains(bits)
            ? image.dataProvider?.data : nil
        let indices = indexedData.flatMap { CFDataGetLength($0) >= image.bytesPerRow * image.height ? CFDataGetBytePtr($0) : nil }
        // Keep the provider's copied data alive while its raw bytes are read below.
        defer { withExtendedLifetime(indexedData) {} }
        if let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            for pixel in 0..<image.width * image.height {
                let i = pixel * 4
                let clear: Bool
                if let indices {
                    let x = pixel % image.width, y = pixel / image.width
                    let index = (Int(indices[y * image.bytesPerRow + x * bits / 8]) >> (8 - bits - x * bits % 8)) & ((1 << bits) - 1)
                    clear = index == 0
                } else if let key = background {
                    clear = abs(Int(pixels[i]) - Int(key.r)) < 3 && abs(Int(pixels[i + 1]) - Int(key.g)) < 3
                        && abs(Int(pixels[i + 2]) - Int(key.b)) < 3
                } else { clear = false }
                if clear { pixels[i] = 0; pixels[i + 1] = 0; pixels[i + 2] = 0; pixels[i + 3] = 0 }
            }
        }

        guard let keyed = context.makeImage() else { return nil }
        let size = image.height
        return (0..<image.width / size).compactMap {
            keyed.cropping(to: CGRect(x: $0 * size, y: 0, width: size, height: size))
        }
    }

    /// The first PLTE entry, which Gen 3 graphics treat as transparent.
    static func backgroundColor(in png: Data) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let bytes = [UInt8](png)
        var offset = 8 // past the PNG signature
        while offset + 11 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            if String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii) == "PLTE" {
                return (bytes[offset + 8], bytes[offset + 9], bytes[offset + 10])
            }
            offset += 12 + length
        }
        return nil
    }
}

/// FireRed's overworld item ball (16×16), thrown in to bring a resting pet back.
let pokeball = SpriteSheet.frames(in: "\(SpriteSheet.directory)/_pokeball.png")?.first

/// Sprites blown up by a whole number with hard pixel edges, for drawing at
/// in-between sizes: scaled the last little way smoothly from there, every
/// pixel stays an even square with just its edges softened, rather than some
/// pixels coming out a screen pixel bigger than their neighbours.
private var sharpened: [ObjectIdentifier: (factor: Int, image: CGImage)] = [:]

private func sharpened(_ image: CGImage, by factor: Int) -> CGImage {
    if let cached = sharpened[ObjectIdentifier(image)], cached.factor == factor { return cached.image }
    let w = image.width * factor, h = image.height * factor
    guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let big = context.makeImage() else { return image }
    sharpened[ObjectIdentifier(image)] = (factor, big)
    return big
}

/// Draws a sprite with crisp pixels into a flipped view, optionally mirrored or faded.
func drawPixelSprite(_ image: CGImage, in rect: NSRect, mirrored: Bool = false, alpha: CGFloat = 1) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.setAlpha(alpha)
    // Screen pixels per sprite pixel. A whole number draws pixel for pixel; anything
    // in between goes through a sharpened copy.
    let device = abs(context.userSpaceToDeviceSpaceTransform.a) * rect.width / CGFloat(image.width)
    var source = image
    if abs(device - device.rounded()) < 0.01 {
        context.interpolationQuality = .none
    } else {
        source = sharpened(image, by: max(1, Int(device)))
        context.interpolationQuality = .high
    }
    // The view is flipped; flip back so the image draws upright.
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    if mirrored {
        context.translateBy(x: rect.width, y: 0)
        context.scaleBy(x: -1, y: 1)
    }
    context.draw(source, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
}

// MARK: - Status art

let iconColors: [Character: NSColor] = [
    "B": NSColor(srgbRed: 0.341, green: 0.412, blue: 0.969, alpha: 1), // working dots
    "S": NSColor(srgbRed: 0.455, green: 0.471, blue: 0.533, alpha: 1), // snoring z's
]
/// The hit flash on a pet that needs you.
let hitRed = NSColor(srgbRed: 1, green: 0.12, blue: 0.12, alpha: 1)

/// The CTX bar: a Gen 3 HP bar that shows how much of an agent's context is left.
enum ContextBar {
    static let outline = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1)
    static let body = NSColor(srgbRed: 0.28, green: 0.28, blue: 0.31, alpha: 1)
    static let label = NSColor(srgbRed: 0.97, green: 0.69, blue: 0.19, alpha: 1)
    static let border = NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 1)
    static let empty = NSColor(srgbRed: 0.22, green: 0.22, blue: 0.25, alpha: 1)
    /// (light, shade) for more than half left, more than a fifth, and the rest.
    static let green = (NSColor(srgbRed: 0.44, green: 0.97, blue: 0.66, alpha: 1), NSColor(srgbRed: 0.28, green: 0.78, blue: 0.47, alpha: 1))
    static let yellow = (NSColor(srgbRed: 0.97, green: 0.88, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.78, green: 0.66, blue: 0.03, alpha: 1))
    static let red = (NSColor(srgbRed: 0.97, green: 0.35, blue: 0.22, alpha: 1), NSColor(srgbRed: 0.69, green: 0.22, blue: 0.19, alpha: 1))
    /// "C", "T", "X" in a 3x5 pixel font.
    static let glyphs = [
        [".##", "#..", "#..", "#..", ".##"],
        ["###", ".#.", ".#.", ".#.", ".#."],
        ["#.#", "#.#", ".#.", "#.#", "#.#"],
    ]
}

// MARK: - Agents (from herdr)

/// One coding agent: a herdr pane, or a Claude Code session reported by the
/// pet's hooks (its `pane` is then "session:<id>").
enum AgentKind: String {
    case claude = "Claude"
    case codex = "Codex"
}

enum AgentBadge {
    /// Use the installed Codex artwork when available. It stays external to
    /// this project and the small centre crop reads clearly inside a dark label.
    static let codexIcon: NSImage? = {
        var paths: [String] = []
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            paths.append(app.appendingPathComponent("Contents/Resources/icon-codex-dark-color.png").path)
        }
        paths.append("/Applications/ChatGPT.app/Contents/Resources/icon-codex-dark-color.png")
        return paths.lazy.compactMap(NSImage.init(contentsOfFile:)).first
    }()
}

struct Agent {
    let pane: String
    let status: String // idle, working, blocked, done, unknown
    let title: String
    let project: String
    var workspace: String = ""
    var kind: AgentKind = .claude
    /// For hook sessions: the terminal app to bring forward, and Claude's process.
    var app: String? = nil
    var pid: pid_t? = nil
    /// How much of its context window remains, 0 to 1, when known.
    var contextLeft: Double? = nil

    var label: String {
        guard !workspace.isEmpty else { return title.isEmpty ? project : "\(project): \(title)" }
        let scope = "[\(project)] [\(workspace)]"
        return title.isEmpty ? scope : "\(scope): \(title)"
    }
}

/// Runs a tool and returns its output, or nil if it can't run or fails.
@discardableResult
func capture(_ path: String, _ args: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return process.terminationStatus == 0 ? data : nil
}

// MARK: - Processes

/// A process's parent and short name, from the kernel.
func processInfo(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafeBytes(of: info.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    return (info.kp_eproc.e_ppid, name)
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

/// The app a process runs inside, such as its terminal, found by walking up its parents.
func hostApp(of pid: pid_t) -> NSRunningApplication? {
    var current = pid
    for _ in 0..<12 {
        if let app = NSRunningApplication(processIdentifier: current), app.bundleIdentifier != nil { return app }
        guard let parent = processInfo(current)?.ppid, parent > 1 else { return nil }
        current = parent
    }
    return nil
}

/// Switches to an agent: through herdr for its panes, otherwise by bringing its terminal forward.
func focus(_ agent: Agent) {
    if agent.pane.hasPrefix(ClaudeApp.prefix) {
        ClaudeApp.open(String(agent.pane.dropFirst(ClaudeApp.prefix.count)))
        return
    }
    if agent.pane.hasPrefix(Conductor.prefix) {
        Conductor.open(String(agent.pane.dropFirst(Conductor.prefix.count)))
        return
    }
    if agent.pane.hasPrefix(CodexSessions.prefix) {
        CodexSessions.open(agent)
        return
    }
    guard agent.pane.hasPrefix(HookSessions.prefix) else {
        Herdr.focus(agent.pane)
        return
    }
    HookSessions.markSeen(String(agent.pane.dropFirst(HookSessions.prefix.count)))
    let app = agent.app.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        ?? agent.pid.flatMap(hostApp(of:))
    app?.activate()
}

// MARK: - Claude app chats

/// Chats in the Claude desktop app, read from its sidebar through the
/// accessibility API, which needs the Accessibility permission. A chat shows a
/// "Running" status beside it while it replies; it's done when that goes.
/// A chat gets a pet once it runs, and keeps it for a day after it last ran.
enum ClaudeApp {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let prefix = "app:"

    struct Chat {
        let title: String
        let status: String? // the status label beside it ("Running"), if any
        let row: AXUIElement
    }

    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    /// Asks once for permission when an installed app needs accessibility-based navigation.
    static func askForAccessIfNeeded() {
        guard (installed || Conductor.installed), !AXIsProcessTrusted(),
              !UserDefaults.standard.bool(forKey: "askedAccessibility") else { return }
        UserDefaults.standard.set(true, forKey: "askedAccessibility")
        askForAccess()
    }

    /// The system's prompt, which points to Privacy & Security → Accessibility.
    static func askForAccess() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    // MARK: Reading the sidebar

    /// The app whose accessibility tree has been switched on (Electron builds it only when asked).
    private static var enabledFor: pid_t = 0
    private static let keys = ["AXRole", "AXSubrole", "AXTitle", "AXDescription", "AXChildren", "AXValue"]

    /// Several attributes in one round trip, leaving out ones the element doesn't have.
    static func values(_ element: AXUIElement, _ names: [String] = keys) -> [String: AnyObject] {
        var list: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &list) == .success,
              let values = list as? [AnyObject] else { return [:] }
        var found: [String: AnyObject] = [:]
        for (name, value) in zip(names, values) {
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError { continue }
            found[name] = value
        }
        return found
    }

    /// The chats in the sidebar, top to bottom, and the one that's open. nil when
    /// the app isn't running, can't be read, or its sidebar is hidden or showing
    /// Code sessions instead of chats.
    static func sidebar() -> (chats: [Chat], open: String?)? {
        guard AXIsProcessTrusted(),
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return nil }
        let app = AXUIElementCreateApplication(running.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.5)
        if enabledFor != running.processIdentifier {
            AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            enabledFor = running.processIdentifier
        }
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXWindows" as CFString, &windows) == .success else { return nil }
        for window in (windows as? [AXUIElement]) ?? [] {
            // Breadth-first to the sidebar, never into the conversation, which can be huge.
            var open: String?
            var sidebar: AXUIElement?
            var queue = [window]
            var visited = 0
            while !queue.isEmpty, visited < 400 {
                let element = queue.removeFirst()
                visited += 1
                let v = values(element)
                if v["AXRole"] as? String == "AXWebArea", let title = v["AXTitle"] as? String, title.hasSuffix(" - Claude") {
                    open = String(title.dropLast(" - Claude".count))
                }
                let subrole = v["AXSubrole"] as? String
                if subrole == "AXLandmarkMain" { continue }
                if subrole == "AXLandmarkComplementary", v["AXDescription"] as? String == "Sidebar" {
                    sidebar = element
                    break
                }
                queue += (v["AXChildren"] as? [AXUIElement]) ?? []
            }
            guard let sidebar else { continue }

            var chats: [Chat] = []
            var titles = Set<String>()
            var showingChats = true
            func isMenu(_ v: [String: AnyObject]) -> Bool {
                (v["AXDescription"] as? String)?.hasPrefix("More options for") == true
            }
            // A chat's row: a titled button, its "More options for …" menu, and while it runs a status.
            func walk(_ element: AXUIElement, depth: Int) {
                guard depth < 25 else { return }
                let v = values(element)
                if v["AXRole"] as? String == "AXRadioButton", v["AXDescription"] as? String == "Claude",
                   let selected = v["AXValue"] as? NSNumber {
                    showingChats = selected.boolValue
                }
                let kids = (v["AXChildren"] as? [AXUIElement]) ?? []
                let parts = kids.map { (element: $0, v: values($0)) }
                if let button = parts.first(where: { $0.v["AXRole"] as? String == "AXButton" && !(($0.v["AXTitle"] as? String) ?? "").isEmpty }),
                   parts.contains(where: { isMenu($0.v) || ((($0.v["AXChildren"] as? [AXUIElement]) ?? []).contains { isMenu(values($0, ["AXDescription"])) }) }) {
                    let title = button.v["AXTitle"] as? String ?? ""
                    let status = parts.first { $0.v["AXSubrole"] as? String == "AXApplicationStatus" }
                        .map { $0.v["AXDescription"] as? String ?? "" }
                    if titles.insert(title).inserted { chats.append(Chat(title: title, status: status, row: button.element)) }
                    return
                }
                for kid in kids { walk(kid, depth: depth + 1) }
            }
            walk(sidebar, depth: 0)
            return showingChats ? (chats, open) : nil
        }
        return nil
    }

    // MARK: Chats as agents

    /// When each chat last ran, kept across restarts.
    private static var lastRan: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "appChats") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "appChats") }
    }
    private static var running = Set<String>()
    /// Chats that finished replying and haven't been opened since.
    private static var finished = Set<String>()
    /// What the chats were last time the sidebar could be read.
    private static var latest: [Agent] = []

    /// Agents for chats that ran in the last day, in the sidebar's order.
    static func agents() -> [Agent] {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            // Closed: they've all stopped.
            running = []
            latest = latest.map {
                Agent(pane: $0.pane, status: $0.status == "done" ? "done" : "idle",
                      title: $0.title, project: $0.project, workspace: $0.workspace, kind: $0.kind)
            }
            return latest
        }
        guard let (chats, open) = sidebar() else { return latest } // hidden for now: keep what we knew
        let now = Date().timeIntervalSince1970
        let viewing = app.isActive ? open : nil
        var ran = lastRan
        var agents: [Agent] = []
        for chat in chats {
            let status: String
            switch chat.status?.lowercased() {
            case nil, "": status = "idle"
            case let label? where ["input", "permission", "approv", "waiting"].contains(where: label.contains): status = "blocked"
            default: status = "working" // "Running"
            }
            if status != "idle" {
                ran[chat.title] = now
                running.insert(chat.title)
            } else if running.remove(chat.title) != nil {
                finished.insert(chat.title)
            }
            if viewing == chat.title { finished.remove(chat.title) }
            guard let last = ran[chat.title], now - last < 86_400 else { continue }
            agents.append(Agent(pane: prefix + chat.title,
                                status: status == "idle" && finished.contains(chat.title) ? "done" : status,
                                title: "", project: chat.title))
        }
        let kept = ran.filter { now - $0.value < 86_400 }
        if kept != lastRan { lastRan = kept }
        latest = agents
        return agents
    }

    /// Brings the Claude app forward on a chat, by pressing its row in the sidebar.
    static func open(_ title: String) {
        if let row = sidebar()?.chats.first(where: { $0.title == title })?.row {
            AXUIElementPerformAction(row, kAXPressAction as CFString)
        }
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
    }
}

// MARK: - Conductor

/// Chats in Conductor (conductor.build), Claude Code and Codex alike, read
/// from the database it keeps them in. Every chat in a workspace that isn't
/// archived gets a pet.
enum Conductor {
    static let bundleID = "com.conductor.app"
    static let prefix = "conductor:"
    static var installed: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }
    static let database = NSHomeDirectory() + "/Library/Application Support/com.conductor.app/conductor.db"

    struct Chat {
        let id: String
        let status: String          // idle, working, error, or needs_... when it's waiting on you
        let live: [String: Any]     // what the chat is doing right now
        let agentType: String       // claude, codex, ...
        let claudeSession: String
        let unread: Int
        let contextPercent: Double?
        let title: String
        let workspace: String       // its id
        let workspaceName: String
        let projectName: String
        let projectWorkspaceCount: Int
    }

    /// nil when Conductor isn't installed, or its database can't be read.
    static func agents(records: [HookSessions.Record]) -> [Agent]? {
        guard let chats = chats() else { return nil }
        // Closed, nothing's running, whatever it last wrote.
        let open = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        let hooks = Dictionary(records.map { ($0.session, $0) }, uniquingKeysWith: { a, _ in a })
        let waitingCodex = open ? CodexSessions.waitingForInput(Set(chats.compactMap {
            $0.agentType.lowercased().contains("codex") && !$0.claudeSession.isEmpty ? $0.claudeSession : nil
        })) : []
        return chats.map { chat in
            let hook = hooks[chat.claudeSession]
            let waiting = !((chat.live["activeQuestions"] as? [Any]) ?? []).isEmpty
                || !(chat.live["activeUserInteraction"] is NSNull || chat.live["activeUserInteraction"] == nil)
                || !(chat.live["proposedPlan"] is NSNull || chat.live["proposedPlan"] == nil)
                || hook?.status == "blocked"
                || waitingCodex.contains(chat.claudeSession)
            let status: String
            if !open { status = chat.unread > 0 ? "done" : "idle" }
            else if waiting || chat.status == "error" || chat.status.hasPrefix("needs") {
                status = "blocked" // a question, a plan to approve, or an error: it needs you either way
            }
            else if chat.live["status"] as? String == "working" || chat.status == "working" { status = "working" }
            else { status = chat.unread > 0 ? "done" : "idle" } // unread until you look at it
            let singleWorkspace = chat.projectWorkspaceCount == 1
            var agent = Agent(pane: prefix + chat.id, status: status,
                              title: singleWorkspace || chat.title == "Untitled" ? "" : chat.title,
                              project: chat.projectName,
                              workspace: singleWorkspace ? "" : chat.workspaceName,
                              kind: chat.agentType.lowercased().contains("codex") ? .codex : .claude,
                              app: bundleID)
            agent.contextLeft = chat.contextPercent.map { max(0, min(1, 1 - $0 / 100)) }
                ?? Context.remaining(transcript: hook?.transcript, model: hook?.model)
            return agent
        }
    }

    static func chats() -> [Chat]? {
        guard FileManager.default.fileExists(atPath: database) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200) // Conductor may be writing
        let query = """
            SELECT s.id, COALESCE(s.status, 'idle'), COALESCE(ss.live_state, ''), COALESCE(s.agent_type, ''),
                   COALESCE(s.claude_session_id, ''), COALESCE(s.unread_count, 0), s.context_used_percent,
                   COALESCE(s.title, ''), w.local_id,
                   COALESCE(NULLIF(w.workspace_name, ''), NULLIF(substr(w.branch, instr(w.branch, '/') + 1), ''),
                            NULLIF(w.directory_name, ''), ''),
                   COALESCE(NULLIF(r.name, ''), NULLIF(w.directory_name, ''), ''),
                   (SELECT COUNT(*) FROM workspaces sibling
                    WHERE sibling.repository_id = w.repository_id
                      AND COALESCE(sibling.state, '') != 'archived'
                      AND COALESCE(sibling.DEPRECATED_archived, 0) = 0)
            FROM sessions s
            JOIN workspaces w ON w.local_id = s.workspace_id
            LEFT JOIN repos r ON r.id = w.repository_id
            LEFT JOIN session_state ss ON ss.session_id = s.id
            WHERE COALESCE(s.is_hidden, 0) = 0 AND s.remote_archived_at IS NULL
              AND COALESCE(w.state, '') != 'archived' AND COALESCE(w.DEPRECATED_archived, 0) = 0
            -- Conductor shows workspaces from hidden repositories in its root
            -- section above the visible project groups. Visible projects follow
            -- their sidebar display order, with recently active workspaces first.
            ORDER BY COALESCE(r.hidden, 0) DESC,
                     CASE WHEN COALESCE(r.hidden, 0) = 0 THEN COALESCE(r.display_order, 0) ELSE 0 END,
                     COALESCE(w.last_activity_at, w.updated_at, w.created_at) DESC,
                     s.created_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        var chats: [Chat] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let live = (try? JSONSerialization.jsonObject(with: Data(text(2).utf8))) as? [String: Any] ?? [:]
            chats.append(Chat(id: text(0), status: text(1), live: live, agentType: text(3), claudeSession: text(4),
                              unread: Int(sqlite3_column_int(statement, 5)),
                              contextPercent: sqlite3_column_type(statement, 6) == SQLITE_NULL
                                  ? nil : sqlite3_column_double(statement, 6),
                              title: text(7), workspace: text(8), workspaceName: text(9), projectName: text(10),
                              projectWorkspaceCount: Int(sqlite3_column_int(statement, 11))))
        }
        return chats
    }

    /// Brings Conductor forward and presses the exact workspace link for this chat.
    /// Retrying briefly also covers launching Conductor from a closed state.
    static func open(_ chat: String) {
        guard let workspace = chats()?.first(where: { $0.id == chat })?.workspace else { return }
        func navigate(_ app: NSRunningApplication) {
            app.activate()
            guard AXIsProcessTrusted() else {
                ClaudeApp.askForAccess()
                return
            }
            DispatchQueue.global().async {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root, 1)
                for attempt in 0..<8 {
                    if let link = workspaceLink(workspace, in: root) {
                        AXUIElementPerformAction(link, kAXPressAction as CFString)
                        return
                    }
                    if attempt < 7 { Thread.sleep(forTimeInterval: 0.15) }
                }
            }
        }
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            navigate(app)
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { app, _ in
                if let app { navigate(app) }
            }
        }
    }

    /// The sidebar link to a workspace, whose address ends in /workspace/<its id>.
    static func workspaceLink(_ workspace: String, in element: AXUIElement, depth: Int = 0) -> AXUIElement? {
        guard depth < 40 else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
           value as? String == "AXLink",
           AXUIElementCopyAttributeValue(element, "AXURL" as CFString, &value) == .success {
            let address = (value as? URL)?.absoluteString ?? value as? String ?? ""
            if URL(string: address)?.path.hasSuffix("/workspace/" + workspace) == true { return element }
        }
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return nil }
        for child in children {
            if let link = workspaceLink(workspace, in: child, depth: depth + 1) { return link }
        }
        return nil
    }
}

// MARK: - herdr

enum Herdr {
    /// herdr wherever it's installed; apps don't get the shell's PATH.
    static let path = [
        NSHomeDirectory() + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    @discardableResult
    static func run(_ args: [String]) -> Data? {
        guard let path else { return nil }
        return capture(path, args)
    }

    /// nil when herdr isn't installed or running.
    static func agents() -> [Agent]? {
        guard let data = run(["agent", "list"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let list = result["agents"] as? [[String: Any]] else { return nil }
        return list.compactMap { entry in
            guard let pane = entry["pane_id"] as? String else { return nil }
            let cwd = entry["foreground_cwd"] as? String ?? entry["cwd"] as? String ?? ""
            return Agent(
                pane: pane,
                status: entry["agent_status"] as? String ?? "unknown",
                title: entry["terminal_title_stripped"] as? String ?? "",
                project: (cwd as NSString).lastPathComponent,
                kind: ((entry["agent_type"] as? String) ?? "").lowercased().contains("codex") ? .codex : .claude
            )
        }
    }

    /// Switches herdr to the agent (marking a done agent as seen) and raises
    /// the terminal herdr is open in.
    static func focus(_ pane: String) {
        DispatchQueue.global().async {
            run(["agent", "focus", pane])
            let client = clientPID()
            DispatchQueue.main.async {
                client.flatMap(hostApp(of:))?.activate()
            }
        }
    }

    /// The herdr client (not the background server), which runs in your terminal.
    static func clientPID() -> pid_t? {
        guard let data = capture("/bin/ps", ["-axo", "pid=,args="]) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = pid_t(parts[0]),
                  (String(parts[1]) as NSString).lastPathComponent == "herdr",
                  !parts.dropFirst(2).contains("server") else { continue }
            return pid
        }
        return nil
    }
}

// MARK: - Claude Code hooks (sessions outside herdr)

/// Claude Code sessions reported by the pet's own hooks, so it works without
/// herdr. `ClaudePet --hook` runs on each hook event and keeps one JSON file
/// per session; the app reads them alongside herdr's agents.
enum HookSessions {
    static let directory = NSHomeDirectory() + "/.local/share/claude-pet/sessions"
    static let prefix = "session:"

    struct Record: Codable {
        var session: String
        var status: String
        var cwd: String
        var pid: Int32?
        var started: Double
        var updated: Double
        var app: String?        // the terminal's bundle id, outside herdr
        var herdrPane: String?  // set when the session runs inside herdr
        var transcript: String?
        var model: String?      // from SessionStart, when Claude Code includes it
    }

    static func url(_ session: String) -> URL { URL(fileURLWithPath: "\(directory)/\(session).json") }

    static func read(_ url: URL) -> Record? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    static func write(_ record: Record) {
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        try? JSONEncoder().encode(record).write(to: url(record.session), options: .atomic)
    }

    /// Runs as a Claude Code hook: records the session's state from the event on stdin.
    /// Prints nothing, since some events show a hook's output to Claude.
    static func handleHook() {
        let started = Date().timeIntervalSince1970 // the event's time, as hooks run in the background
        guard let event = try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as? [String: Any],
              let session = event["session_id"] as? String, !session.isEmpty,
              !session.contains("/"),
              let name = event["hook_event_name"] as? String else { return }

        if name == "SessionEnd" {
            try? FileManager.default.removeItem(at: url(session))
            return
        }
        let status: String
        switch name {
        case "SessionStart", "StopFailure": status = "idle"
        case "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure": status = "working"
        case "PermissionRequest", "Notification": status = "blocked" // Notification is matched to prompts only
        case "Stop": status = "done"
        default: return
        }

        var record = read(url(session)) ?? Record(session: session, status: status, cwd: "", pid: nil,
                                                  started: started, updated: 0)
        // A hook that started earlier but finished later mustn't undo a newer state.
        guard started >= record.updated else { return }
        let env = ProcessInfo.processInfo.environment
        record.status = status
        record.updated = started
        record.cwd = event["cwd"] as? String ?? record.cwd
        record.transcript = event["transcript_path"] as? String ?? record.transcript
        record.model = event["model"] as? String ?? record.model
        record.pid = claudePID()
        record.herdrPane = env["HERDR_PANE_ID"]
        record.app = record.herdrPane == nil ? env["__CFBundleIdentifier"] : nil
        write(record)
    }

    /// Claude Code's process: the hook's parent, skipping any shell in between.
    static func claudePID() -> pid_t {
        var pid = getppid()
        for _ in 0..<4 {
            guard let info = processInfo(pid), ["sh", "bash", "zsh", "dash", "fish"].contains(info.name) else { break }
            pid = info.ppid
        }
        return pid
    }

    /// Every live session, including ones inside herdr. Drops (and deletes)
    /// ones whose Claude has exited.
    static func liveRecords() -> [Record] {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let now = Date().timeIntervalSince1970
        var records: [Record] = []
        for file in files where file.hasSuffix(".json") {
            let url = URL(fileURLWithPath: "\(directory)/\(file)")
            guard var record = read(url) else { continue }
            let gone = record.pid.map { !isAlive($0) } ?? (now - record.updated > 86_400)
            if gone {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if (record.status == "working" || record.status == "blocked") && wasInterrupted(record) {
                record.status = "idle"
                write(record)
            }
            records.append(record)
        }
        return records
    }

    /// The sessions to show as their own pets, oldest first: all of them, less
    /// the ones inside herdr while herdr is reporting them itself.
    static func agents(from records: [Record], herdrRunning: Bool) -> [Agent] {
        records.filter { !($0.herdrPane != nil && herdrRunning) }.sorted { $0.started < $1.started }.map {
            Agent(pane: prefix + $0.session, status: $0.status, title: "",
                  project: ($0.cwd as NSString).lastPathComponent, app: $0.app, pid: $0.pid)
        }
    }

    /// Whether you pressed Esc since the last hook. Claude Code runs no hook
    /// for an interrupt or a denied prompt, but writes a marker to the transcript.
    static func wasInterrupted(_ record: Record) -> Bool {
        guard let path = record.transcript,
              let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
              modified.timeIntervalSince1970 > record.updated,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 16_384 ? size - 16_384 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        // The latest message, skipping the metadata lines written after it.
        let last = tail.split(separator: "\n").last {
            $0.contains("\"type\":\"user\"") || $0.contains("\"type\":\"assistant\"")
        }
        return last?.contains("[Request interrupted by user") ?? false
    }

    /// Clears a finished session's "done" once you've clicked through to it.
    static func markSeen(_ session: String) {
        guard var record = read(url(session)), record.status == "done" else { return }
        record.status = "idle"
        write(record)
    }
}

/// Tracks actual question calls, not ordinary background work or tool execution.
enum CodexActivity {
    struct State {
        var phase = "idle"
        var context: Double?
        // True means asynchronous: its "accepted" output is not the user's answer.
        var questions: [String: Bool] = [:]
        var status: String { questions.isEmpty ? phase : "blocked" }

        mutating func consume(_ line: Data) {
            guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let type = json["type"] as? String,
                  let payload = json["payload"] as? [String: Any],
                  let item = payload["type"] as? String else { return }
            if type == "event_msg" {
                switch item {
                case "task_started", "turn_started": phase = "working"
                case "task_complete", "turn_complete":
                    phase = "done"
                    questions = questions.filter { $0.value }
                case "turn_aborted":
                    phase = "idle"
                    questions.removeAll()
                case "user_message": questions.removeAll()
                case "token_count":
                    if let info = payload["info"] as? [String: Any],
                       let usage = info["last_token_usage"] as? [String: Any],
                       let tokens = usage["total_tokens"] as? NSNumber,
                       let window = info["model_context_window"] as? NSNumber, window.doubleValue > 0 {
                        context = tokens.doubleValue / window.doubleValue
                    }
                default: break
                }
            } else if type == "response_item" {
                if item == "message", payload["role"] as? String == "user" {
                    questions.removeAll()
                } else if item == "function_call" || item == "custom_tool_call" {
                    let name = ((payload["name"] as? String) ?? "").split(separator: ".").last.map(String.init) ?? ""
                    if ["request_user_input", "request_user_input_async"].contains(name),
                       let id = payload["call_id"] as? String {
                        questions[id] = name == "request_user_input_async"
                    }
                } else if item == "function_call_output" || item == "custom_tool_call_output",
                          let id = payload["call_id"] as? String, let asynchronous = questions[id] {
                    let output = (payload["output"] as? String).flatMap { $0.data(using: .utf8) }
                        .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
                    if !asynchronous || output?["accepted"] as? Bool != true {
                        questions.removeValue(forKey: id)
                    }
                }
            }
        }
    }

    private struct Cached {
        var inode: UInt64
        var offset: UInt64 = 0
        var partial = Data()
        var state = State()
    }
    private static var cache: [String: Cached] = [:]

    /// Read each log once, then only appended bytes. A pending async question
    /// must not disappear just because tool output pushed it out of a short tail.
    static func read(_ path: String) -> State? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let handle = FileHandle(forReadingAtPath: path) else {
            cache.removeValue(forKey: path)
            return nil
        }
        defer { try? handle.close() }
        var entry = cache[path] ?? Cached(inode: inode)
        if entry.inode != inode || size < entry.offset { entry = Cached(inode: inode) }
        do {
            try handle.seek(toOffset: entry.offset)
            while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                entry.offset += UInt64(chunk.count)
                entry.partial.append(chunk)
                var start = entry.partial.startIndex
                while let newline = entry.partial[start...].firstIndex(of: 10) {
                    entry.state.consume(Data(entry.partial[start..<newline]))
                    start = entry.partial.index(after: newline)
                }
                entry.partial = Data(entry.partial[start...])
            }
        } catch { return nil }
        cache[path] = entry
        return entry.state
    }
}

// MARK: - Codex sessions

/// Live Codex CLI, ChatGPT desktop, Conductor, and Orca chats. Codex holds one
/// writer lock per open thread and records that thread's title, project, events,
/// and context usage in its local state database.
enum CodexSessions {
    static let prefix = "codex:"

    struct Store {
        let home: String
        var database: String { home + "/state_5.sqlite" }
        var locks: String { home + "/thread-writer-locks" }
    }

    /// Codex Desktop and the standalone CLI use ~/.codex. Orca can isolate
    /// accounts into their own Codex homes, so include every one it manages.
    static func stores() -> [Store] {
        var homes = [NSHomeDirectory() + "/.codex"]
        let orca = NSHomeDirectory() + "/Library/Application Support/orca"
        homes.append(orca + "/codex-runtime-home/home")
        if let accounts = try? FileManager.default.contentsOfDirectory(atPath: orca + "/codex-accounts") {
            homes += accounts.map { orca + "/codex-accounts/\($0)/home" }
        }
        var seen = Set<String>()
        return homes.filter { seen.insert($0).inserted && FileManager.default.fileExists(atPath: $0 + "/state_5.sqlite") }
            .map(Store.init)
    }

    struct Thread {
        let id: String
        let rollout: String
        let cwd: String
        let title: String
        let source: String
        let originator: String
        let branch: String
        let agentPath: String
        let pid: pid_t
    }

    /// Thread ids and the Codex process holding each one. This intentionally
    /// ignores historical threads, so a closed CLI chat does not leave a pet.
    static func liveProcesses(in store: Store) -> [String: pid_t] {
        guard let locks = try? FileManager.default.contentsOfDirectory(atPath: store.locks),
              locks.contains(where: { $0.hasSuffix(".lock") && $0 != ".coordination.lock" }),
              let data = capture("/usr/sbin/lsof", ["-Fpcn", "+D", store.locks]) else { return [:] }
        var pid: pid_t?
        var found: [String: pid_t] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            if line.first == "p" { pid = pid_t(line.dropFirst()) }
            guard line.first == "n", let pid else { continue }
            let file = (String(line.dropFirst()) as NSString).lastPathComponent
            guard file.hasSuffix(".lock"), file != ".coordination.lock" else { continue }
            let id = String(file.dropLast(".lock".count))
            if id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) { found[id] = pid }
        }
        return found
    }

    static func threads(excluding excluded: Set<String>) -> [Thread] {
        var found: [String: Thread] = [:]
        for store in stores() {
            for thread in threads(in: store, excluding: excluded) { found[thread.id] = thread }
        }
        return found.values.sorted { $0.id < $1.id }
    }

    static func threads(in store: Store, excluding excluded: Set<String>) -> [Thread] {
        let live = liveProcesses(in: store).filter { !excluded.contains($0.key) }
        guard !live.isEmpty else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(store.database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        let query = """
            SELECT rollout_path, cwd, COALESCE(NULLIF(name, ''), NULLIF(preview, ''), NULLIF(title, ''), ''),
                   source, COALESCE(originator, ''), COALESCE(git_branch, ''), COALESCE(agent_path, '')
            FROM threads WHERE id = ? AND archived = 0
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        func text(_ i: Int32) -> String { sqlite3_column_text(statement, i).map { String(cString: $0) } ?? "" }
        var threads: [Thread] = []
        for (id, pid) in live {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_ROW else { continue }
            threads.append(Thread(id: id, rollout: text(0), cwd: text(1), title: cleanTitle(text(2)),
                                  source: text(3), originator: text(4), branch: text(5),
                                  agentPath: text(6), pid: pid))
        }
        return threads
    }

    /// The last turn boundary in a rollout tells us whether Codex is working,
    /// waiting for input, or finished. The most recent token event supplies CTX.
    static func state(of thread: Thread) -> (status: String, context: Double?) {
        guard let activity = CodexActivity.read(thread.rollout) else { return ("idle", nil) }
        var status = activity.status
        if status == "done", modifiedAt(thread.rollout) <= seenAt(thread.id) { status = "idle" }
        return (status, activity.context)
    }

    /// Conductor owns these pets, but its persisted live state can omit Codex
    /// questions. Resolve their rollouts without requiring a separate CLI pet.
    static func waitingForInput(_ ids: Set<String>, in sources: [Store] = stores()) -> Set<String> {
        guard !ids.isEmpty else { return [] }
        var waiting = Set<String>()
        for store in sources {
            var db: OpaquePointer?
            guard sqlite3_open_v2(store.database, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
                sqlite3_close(db)
                continue
            }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 200)
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE id = ? AND archived = 0",
                                    -1, &statement, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(statement) }
            for id in ids {
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
                sqlite3_bind_text(statement, 1, id, -1, SQLITE_TRANSIENT)
                guard sqlite3_step(statement) == SQLITE_ROW,
                      let text = sqlite3_column_text(statement, 0) else { continue }
                if CodexActivity.read(String(cString: text))?.status == "blocked" { waiting.insert(id) }
            }
        }
        return waiting
    }

    static func agents(excluding excluded: Set<String>) -> [Agent] {
        threads(excluding: excluded).map { thread in
            let state = state(of: thread)
            let app = hostApp(of: thread.pid)?.bundleIdentifier
            let scope = projectAndWorkspace(for: thread)
            return Agent(pane: prefix + thread.id, status: state.status, title: thread.title,
                         project: scope.project, workspace: scope.workspace, kind: .codex,
                         app: app, pid: thread.pid,
                         contextLeft: state.context.map { max(0, min(1, 1 - $0)) })
        }
    }

    static func projectAndWorkspace(for thread: Thread) -> (project: String, workspace: String) {
        let parts = URL(fileURLWithPath: thread.cwd).pathComponents
        if let i = parts.lastIndex(of: "workspaces"), i + 2 < parts.count {
            return (parts[i + 1], workspaceName(thread) ?? parts[i + 2])
        }
        if let i = parts.lastIndex(of: "projects"), i + 1 < parts.count {
            return (parts[i + 1], workspaceName(thread) ?? "root")
        }
        let project = (thread.cwd as NSString).lastPathComponent.isEmpty
            ? (thread.originator.isEmpty ? "Codex" : thread.originator)
            : (thread.cwd as NSString).lastPathComponent
        return (project, workspaceName(thread) ?? "root")
    }

    static func workspaceName(_ thread: Thread) -> String? {
        if !thread.agentPath.isEmpty { return thread.agentPath.split(separator: "/").last.map(String.init) }
        let branch = thread.branch.split(separator: "/").last.map(String.init) ?? ""
        return branch.isEmpty || branch == "main" || branch == "master" ? nil : branch
    }

    static func cleanTitle(_ raw: String) -> String {
        var value = raw
        if let end = value.range(of: "</system_instruction>", options: .backwards) { value = String(value[end.upperBound...]) }
        let words = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let title = words.joined(separator: " ")
        guard title.count > 80 else { return title }
        return String(title.prefix(79)) + "…"
    }

    static func modifiedAt(_ path: String) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }

    static func seenAt(_ id: String) -> Double {
        (UserDefaults.standard.dictionary(forKey: "codexSeen") as? [String: Double])?[id] ?? 0
    }

    static func markSeen(_ id: String) {
        var seen = UserDefaults.standard.dictionary(forKey: "codexSeen") as? [String: Double] ?? [:]
        let rollout = threads(excluding: []).first { $0.id == id }?.rollout
        seen[id] = rollout.map(modifiedAt) ?? Date().timeIntervalSince1970
        UserDefaults.standard.set(seen, forKey: "codexSeen")
    }

    static func open(_ agent: Agent) {
        let id = String(agent.pane.dropFirst(prefix.count))
        markSeen(id)
        if agent.app == "com.openai.codex", let url = URL(string: "codex://threads/\(id)") {
            NSWorkspace.shared.open(url)
            return
        }
        let app = agent.app.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
            ?? agent.pid.flatMap(hostApp(of:))
        app?.activate()
    }
}

// MARK: - Pet

/// `stored` is back in its Poké Ball: 12 hours unused, or recalled from the menu.
enum Mood { case idle, working, alert, done, sleeping, stored }

/// Going into the Poké Ball (a red glow, shrinking away to nothing) or coming
/// out of it (a white flash).
struct Transition {
    enum Kind { case recall, release }
    let kind: Kind
    let start: Int // tick it began
    var ticks: Int { kind == .recall ? 8 : 6 }
}

/// When each herdr pane last worked or asked for input, kept across restarts.
enum LastActive {
    static let key = "lastActive"

    static func get(_ pane: String) -> Date? {
        (UserDefaults.standard.dictionary(forKey: key)?[pane] as? Double).map(Date.init(timeIntervalSince1970:))
    }

    static func set(_ pane: String, _ date: Date) {
        var all = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        all[pane] = date.timeIntervalSince1970
        UserDefaults.standard.set(all, forKey: key)
    }
}

/// How big the pets are, from the Size slider in the right-click menu. The
/// slider moves freely from small to large but holds for a moment at each of
/// the three sizes on the way.
enum PetSize {
    static let small: CGFloat = 1.5, medium: CGFloat = 3, large: CGFloat = 4.5
    static let locks = [small, medium, large]
    /// How close the knob has to come to one of the sizes before it holds there.
    static let pull: CGFloat = 0.3

    /// The slider's position, kept across restarts.
    static var saved: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: "petSize")
            return value == 0 ? medium : min(large, max(small, CGFloat(value)))
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: "petSize") }
    }

    /// The slider's value, pulled onto a size when it's close to one.
    static func settle(_ value: CGFloat) -> CGFloat { locks.first { abs($0 - value) <= pull } ?? value }

    /// Points per sprite pixel: any size, following the slider smoothly (see drawPixelSprite).
    static func scale(for value: CGFloat) -> CGFloat { value }
}

/// A short, one-shot burst. The existing animation clock drives it without extra timers.
struct ShinyHoverBurst {
    static let duration = 10
    static let pattern = ["...G...", "...Y...", "..YWY..", "GYWWWYG", "..YWY..", "...Y...", "...G..."]
    private(set) var start: Int?

    mutating func begin(at tick: Int) {
        if progress(at: tick) == nil { start = tick }
    }
    mutating func reset() { start = nil }
    func progress(at tick: Int) -> CGFloat? {
        guard let start, tick >= start, tick - start < Self.duration else { return nil }
        return CGFloat(tick - start) / CGFloat(Self.duration)
    }

    struct Star {
        let origin: NSPoint
        let pixel: CGFloat
        let alpha: CGFloat
        var frame: NSRect { NSRect(origin: origin, size: NSSize(width: 7 * pixel, height: 7 * pixel)) }
    }

    func stars(at tick: Int, around box: NSRect, in bounds: NSRect, scale: CGFloat) -> [Star] {
        guard let progress = progress(at: tick) else { return [] }
        let basePixel = max(1, (scale * 0.65).rounded())
        let center = NSPoint(x: box.midX, y: box.midY)
        // Stay inside the transparent window, including large and wide species.
        let rx = max(0, min(box.width / 2 + 10 * scale,
                            min(center.x - bounds.minX, bounds.maxX - center.x) - 4 * basePixel))
        let ry = max(0, min(box.height / 2 + 10 * scale,
                            min(center.y - bounds.minY, bounds.maxY - center.y) - 4 * basePixel))
        return (0..<8).map { i in
            let p = max(0, min(1, progress * 1.2 - CGFloat(i % 3) * 0.08))
            let angle = CGFloat(i) * .pi / 4 + .pi / 8 + p * 0.25
            let distance = 0.25 + 0.75 * (1 - pow(1 - p, 2))
            let pixel = p > 0.72 ? max(1, (basePixel / 2).rounded()) : basePixel
            let x = ((center.x + cos(angle) * rx * distance) / pixel).rounded() * pixel - 3 * pixel
            let y = ((center.y + sin(angle) * ry * distance) / pixel).rounded() * pixel - 3 * pixel
            let twinkle: CGFloat = (tick + i) % 3 == 0 ? 0.65 : 1
            return Star(origin: NSPoint(x: x, y: y), pixel: pixel, alpha: min(1, (1 - p) * 2.5) * twinkle)
        }
    }
}

final class PetView: NSView {
    static let width: CGFloat = 320
    /// Screen points per sprite pixel, from the Size slider (3 is medium).
    static var scale = PetSize.scale(for: PetSize.saved)
    static func height(for sheet: SpriteSheet) -> CGFloat {
        spriteTop + CGFloat(sheet.frames[0].width) * scale + bottomPad
    }
    /// Room under the ground for the working dots and the done caption.
    static let bottomPad: CGFloat = 22
    static let captionFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
    /// Off for the render modes, so their pretend agents aren't saved.
    static var recordsActivity = true
    /// How far the "is done" caption reaches below the ground. The stack leaves
    /// this much room under every pet, so a caption never covers the pet below.
    static var captionDepth: CGFloat {
        2 + ("Ag" as NSString).size(withAttributes: [.font: captionFont]).height + 4
    }
    // Layout, top-down (the view is flipped): room for jumps and drifting z's,
    // the sprite, then room for the dots or the caption (its status, or "is
    // done") under it. The sprite is centred across the window.
    static let spriteTop: CGFloat = 48
    /// How far it paces either side while working. Less in a row, where
    /// neighbours stand close enough that they'd walk into each other.
    var pace = PetView.columnPace
    /// In a horizontal line-up, every second caption sits above its pet so
    /// adjacent completion messages do not cover each other.
    var captionAbove = false
    static let columnPace: CGFloat = 12
    static let rowPace: CGFloat = 4

    /// Flat, object-like Pokémon read more naturally as rotating mechanisms
    /// than as little animals pacing from side to side.
    static let spinningPokemon: Set<String> = [
        "magnemite", "magneton", "voltorb", "electrode", "unown",
        "baltoy", "claydol", "lunatone", "solrock", "bronzor", "bronzong",
        "magnezone", "rotom", "klink", "klang", "klinklang", "cryogonal",
    ]

    /// Where the sprite rests: the middle of the window, so the caption under
    /// it can centre. At a screen edge the window hangs past it (see PetPanel).
    var homeX: CGFloat { (bounds.width - spriteSize) / 2 }

    private(set) var agent: Agent
    private(set) var pokemon: String
    private(set) var isShiny = false
    private(set) var shinyBurst = ShinyHoverBurst()
    private var sheet: SpriteSheet

    var onMoved: ((PetView) -> Void)?
    /// Shift-dragging moves every pet: called with how far the mouse has gone, then nil when it's let go.
    var onDragAll: ((NSPoint?) -> Void)?
    var onChoosePokemon: ((PetView, String) -> Void)?
    var onLineUp: (() -> Void)?
    /// Called as the Size slider moves, with its value.
    var onSize: ((CGFloat) -> Void)?
    /// Called once it has gone into its ball, to close up the gap it leaves.
    var onVanish: (() -> Void)?
    /// Called when it's coming back out, to make room and throw its ball in.
    var onSummon: ((PetView) -> Void)?
    /// The pets resting out of sight, for Let Out.
    var restingPets: (() -> [PetView])?
    /// The Pokémon other live agents have, so the picker can show them as taken.
    var otherPokemon: (() -> Set<String>)?

    var mood = Mood.idle
    var tick = Int.random(in: 0..<64) // so pets don't move in lockstep
    var walkX: CGFloat = 0
    var walkDirection: CGFloat = 1
    var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            // Lift the hovered pet above its neighbours so its label shows on top.
            window?.level = hovering ? NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) : .floating
            if hovering && isShiny && !arriving && mood != .stored && transition == nil {
                shinyBurst.begin(at: tick)
            }
            needsDisplay = true
        }
    }
    var hopUntil = Date.distantPast
    var labelUntil = Date.distantPast
    var lastBusy: Date
    var previousStatus: String?
    var finishedAt: Date?
    var contextLeft: Double?
    var transition: Transition?
    /// While its Poké Ball is in the air there's nothing to draw here yet.
    var arriving = false
    /// Set by its first update, so a pet that starts out resting is simply out of sight.
    var settled = false

    /// Resting out of sight, once it has gone into its ball.
    var isGone: Bool { mood == .stored && transition == nil }

    init(agent: Agent, pokemon: String, sheet: SpriteSheet) {
        self.agent = agent
        self.pokemon = pokemon
        self.sheet = sheet
        if let saved = LastActive.get(agent.pane) {
            lastBusy = saved
        } else {
            lastBusy = Date()
            if Self.recordsActivity { LastActive.set(agent.pane, lastBusy) }
        }
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(for: sheet)))
        if Self.recordsActivity { updateAppearance() }
    }

    /// Records activity, saving it at most once a minute.
    func markActive(_ now: Date = Date()) {
        if now.timeIntervalSince(lastBusy) > 60 { LastActive.set(agent.pane, now) }
        lastBusy = now
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var name: String { PokemonCatalog.displayName(for: pokemon) }
    var spriteSize: CGFloat { CGFloat(sheet.frames[0].width) * Self.scale }
    var spinsWhileWorking: Bool { Self.spinningPokemon.contains(pokemon) }

    func setPokemon(_ name: String, sheet: SpriteSheet) {
        pokemon = name
        if Self.recordsActivity { ShinyEncounters.save(false, pane: agent.pane, pokemon: name) }
        applyAppearance(sheet: sheet, shiny: false)
    }

    func applyAppearance(sheet: SpriteSheet, shiny: Bool) {
        self.sheet = sheet
        isShiny = shiny
        shinyBurst.reset()
        fitSize()
    }

    private func updateAppearance(reroll: Bool = false) {
        let shiny = ShinyEncounters.resolve(pane: agent.pane, pokemon: pokemon, reroll: reroll)
        if let selected = SpriteSheet.named(pokemon, shiny: shiny) {
            applyAppearance(sheet: selected, shiny: shiny)
        } else if let normal = SpriteSheet.named(pokemon) {
            applyAppearance(sheet: normal, shiny: false)
        }
        needsDisplay = true
    }

    /// Matches the view and its window to the sprite, keeping the ground anchored.
    func fitSize() {
        let size = NSSize(width: Self.width, height: Self.height(for: sheet))
        // Changing the content view alone leaves a larger sprite clipped by its old window.
        if let window, window.contentView === self {
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: true)
        }
        setFrameSize(size)
        needsDisplay = true
    }

    func update(_ latest: Agent) {
        let now = Date()
        if previousStatus == "working" && latest.status != "working" {
            finishedAt = now
        } else if latest.status == "done" && finishedAt == nil {
            finishedAt = now
        }
        previousStatus = latest.status
        agent = latest
        contextLeft = latest.contextLeft

        let next: Mood
        switch latest.status {
        case "blocked": next = .alert
        case "working": next = .working
        default:
            // herdr's done lasts until the agent is viewed; a plain stop counts briefly.
            let quiet = now.timeIntervalSince(lastBusy)
            if let at = finishedAt,
               now.timeIntervalSince(at) < (latest.status == "done" ? 900 : 15) {
                next = .done
            } else if quiet > 12 * 3600 {
                next = .stored
            } else if quiet > 600 {
                next = .sleeping
            } else {
                next = .idle
            }
        }
        if next == .working || next == .alert { markActive(now) }
        setMood(next)
    }

    /// Changes mood. Going into its ball it glows red and shrinks away; coming
    /// back out, its ball is thrown in and it pops out where it lands.
    func setMood(_ next: Mood) {
        guard settled else {
            settled = true
            mood = next
            return
        }
        let wasGone = isGone
        if next == .stored && mood != .stored {
            shinyBurst.reset()
            transition = Transition(kind: .recall, start: tick)
        } else if mood == .stored && next != .stored {
            if Self.recordsActivity { updateAppearance(reroll: true) }
            // Called back mid-recall, it just comes straight back out.
            transition = wasGone ? nil : Transition(kind: .release, start: tick)
            arriving = wasGone
        }
        if next != mood && next == .alert { // done has its own caption
            labelUntil = Date().addingTimeInterval(5)
        }
        mood = next
        if wasGone && next != .stored { onSummon?(self) }
    }

    /// Its ball has landed: out it comes.
    func land() {
        arriving = false
        transition = Transition(kind: .release, start: tick)
        hopUntil = Date().addingTimeInterval(1.6) // a happy hop once it's out
        needsDisplay = true
    }

    /// How far the pet reaches above the ground in points, from its topmost pixel.
    var visibleHeight: CGFloat { CGFloat(sheet.frames[0].height - sheet.top) * Self.scale }

    /// How much room the pet needs across, for lining up in a row: its sprite at
    /// its widest plus its pacing room.
    var footprintWidth: CGFloat { CGFloat(2 * sheet.halfWidth) * Self.scale + 2 * pace }

    /// Recalls the pet into its Poké Ball until you let it out or its agent gets busy.
    @objc func returnToBall() {
        lastBusy = .distantPast
        LastActive.set(agent.pane, .distantPast)
        finishedAt = nil
        setMood(.stored)
    }

    /// Brings the pet out of its ball, or wakes it from a nap.
    @objc func wake() {
        let now = Date()
        lastBusy = now
        LastActive.set(agent.pane, now)
        if mood == .stored || mood == .sleeping {
            setMood(.idle)
            if !arriving { hopUntil = now.addingTimeInterval(1.4) } // a happy hop once it's out
        }
    }

    var summary: String { agent.label }

    /// Advances one animation step: walks or spins while working, and walks home after.
    func animate() {
        tick += 1
        if let transition, tick - transition.start >= transition.ticks {
            self.transition = nil
            if transition.kind == .recall {
                hovering = false
                onVanish?()
            }
        }
        let speed: CGFloat = 2
        if mood == .working && !spinsWhileWorking {
            walkX += walkDirection * speed
            if abs(walkX) >= pace { walkDirection = walkX > 0 ? -1 : 1 }
        } else if walkX != 0 {
            walkDirection = walkX > 0 ? -1 : 1
            walkX = abs(walkX) <= speed ? 0 : walkX + walkDirection * speed
        }
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        if let transition {
            let progress = CGFloat(tick - transition.start) / CGFloat(transition.ticks)
            if progress < 1 {
                drawTransition(transition.kind, progress: max(progress, 0), ball: pokeball)
                return
            }
        }
        if arriving || mood == .stored { return }
        let frames = sheet.frames
        let step = tick / 2 % 2
        var image = frames[tick / 6 % 2]
        var mirrored = false
        var lift: CGFloat = 0
        var flash = false
        let spinning = mood == .working && spinsWhileWorking
        let walking = !spinning && (walkX != 0 || mood == .working)

        if walking {
            let right = walkDirection > 0
            if right && frames.count >= 8 {
                image = frames[6 + step]
            } else {
                image = frames[4 + step]
                mirrored = right
            }
        } else if spinning {
            // Turn on the ground through front, side, back, and the other side.
            // The sprite stays centred instead of rotating as a flat picture.
            let turn = tick / 3 % 4
            let turnStep = tick / 2 % 2
            switch turn {
            case 0:
                image = frames[turnStep]
            case 1:
                image = frames[4 + turnStep]
            case 2:
                image = frames[2 + turnStep]
            default:
                if frames.count >= 8 {
                    image = frames[6 + turnStep]
                } else {
                    image = frames[4 + turnStep]
                    mirrored = true
                }
            }
        }

        switch mood {
        case .alert:
            if !walking { image = frames[step] }
            lift = tick / 3 % 2 == 0 ? 0 : 8
            flash = tick / 2 % 2 == 0 // hard on/off, like taking a hit: 250ms each
        case .done:
            if !walking { image = frames[step] }
            lift = [0, 6, 14, 18, 14, 6, 0, 0, 0, 0][tick % 10]
        case .working:
            break
        case .sleeping, .stored:
            if !walking { image = frames[0] }
        case .idle:
            if !walking && (hovering || Date() < hopUntil) {
                image = frames[step]
                lift = [0, 4, 6, 4][tick % 4]
            }
        }

        let rect = NSRect(x: homeX + walkX, y: Self.spriteTop - lift,
                          width: spriteSize, height: spriteSize)
        // Only a pet off the ground casts a shadow.
        if lift > 0 { drawShadow(frame: rect, pixels: sheet.frames[0].width, width: 14, lift: lift) }
        if flash {
            drawTinted(image, in: rect, color: hitRed, amount: 0.85, mirrored: mirrored)
        } else {
            drawSprite(image, in: rect, mirrored: mirrored)
        }
        drawShinyBurst(lift: lift)

        switch mood {
        case .working: drawWorkingDots(under: rect)
        case .sleeping, .stored: drawSnores(over: rect)
        default: break
        }
        let headTop = rect.minY + CGFloat(sheet.top) * Self.scale
        drawContextBarIfShown(headTop: headTop)
        // One caption under the pet: its status while hovered (or just after it
        // needs you), otherwise "is done" when it has finished.
        if hovering || Date() < labelUntil {
            drawCaption(summary, badge: agent.kind, headTop: headTop)
        } else if mood == .done {
            drawCaption("\(name) is done", headTop: headTop)
        }
    }

    /// Where the ground is: the bottom of the resting sprite frame.
    var ground: CGFloat { Self.spriteTop + spriteSize }

    func drawShinyBurst(lift: CGFloat) {
        guard isShiny, shinyBurst.progress(at: tick) != nil else { return }
        let colors: [Character: NSColor] = [
            "G": NSColor(srgbRed: 0.85, green: 0.51, blue: 0.08, alpha: 1),
            "Y": NSColor(srgbRed: 1, green: 0.85, blue: 0.24, alpha: 1),
            "W": NSColor(srgbRed: 1, green: 1, blue: 0.88, alpha: 1),
        ]
        for star in shinyBurst.stars(at: tick, around: hitBox.offsetBy(dx: 0, dy: -lift), in: bounds, scale: Self.scale) {
            for (row, line) in ShinyHoverBurst.pattern.enumerated() {
                for (col, key) in line.enumerated() {
                    guard let color = colors[key] else { continue }
                    color.withAlphaComponent(star.alpha).setFill()
                    NSRect(x: star.origin.x + CGFloat(col) * star.pixel, y: star.origin.y + CGFloat(row) * star.pixel,
                           width: star.pixel, height: star.pixel).fill()
                }
            }
        }
    }

    /// One to three dots, centred just under the pet, while it works.
    func drawWorkingDots(under rect: NSRect) {
        let count = tick / 3 % 3 + 1
        let dot: CGFloat = 4, spacing: CGFloat = 4
        let left = (rect.midX - (3 * dot + 2 * spacing) / 2).rounded()
        iconColors["B"]?.setFill()
        for i in 0..<count {
            NSRect(x: left + CGFloat(i) * (dot + spacing), y: ground + 4, width: dot, height: dot).fill()
        }
    }

    /// The part of this view that's on screen (all of it when rendering offscreen).
    var onScreenRect: NSRect {
        guard let window, let screen = window.screen ?? NSScreen.main else { return bounds }
        let shown = window.frame.intersection(screen.visibleFrame)
        guard !shown.isEmpty else { return bounds }
        let inWindow = NSRect(origin: NSPoint(x: shown.minX - window.frame.minX, y: shown.minY - window.frame.minY),
                              size: shown.size)
        return convert(inWindow, from: nil)
    }

    /// A caption centred under the pet, such as "Pikachu is done" or its status,
    /// slid inward only as far as it takes to stay on screen.
    func drawCaption(_ text: String, badge: AgentKind? = nil, headTop: CGFloat? = nil) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.captionFont, .foregroundColor: NSColor.white]
        let room = onScreenRect.intersection(bounds).insetBy(dx: 4, dy: 0)
        let badgeRoom: CGFloat = badge == nil ? 0 : 17
        var shown = text
        var keep = text.count
        while (shown as NSString).size(withAttributes: attrs).width + 12 + badgeRoom > room.width && keep > 1 {
            keep -= 1
            shown = String(text.prefix(keep)) + "…"
        }
        let size = (shown as NSString).size(withAttributes: attrs)
        let width = size.width + 12 + badgeRoom
        let x = min(max(homeX + spriteSize / 2 - width / 2, room.minX), room.maxX - width)
        let height = size.height + 4
        var topAnchor = headTop
        if captionAbove, let remaining = contextLeft, hovering || remaining <= 0.2, let headTop {
            let px = max(1, (Self.scale * 4 / 3).rounded() / 2)
            topAnchor = headTop - 3 - 7 * px
        }
        let y = captionAbove && topAnchor != nil ? max(0, topAnchor! - height - 5) : ground + 2
        let pill = NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
        NSColor(white: 0.1, alpha: 0.85).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        if let badge { drawAgentBadge(badge, at: NSPoint(x: pill.minX + 12.5, y: pill.midY)) }
        (shown as NSString).draw(at: NSPoint(x: pill.minX + 6 + badgeRoom, y: pill.minY + 2), withAttributes: attrs)
    }

    /// A tiny logo-like marker distinguishes providers without adding another
    /// word to an already detailed project, workspace, and chat label.
    func drawAgentBadge(_ kind: AgentKind, at point: NSPoint) {
        switch kind {
        case .claude:
            let r: CGFloat = 4
            let star = NSBezierPath()
            star.move(to: NSPoint(x: point.x, y: point.y - r))
            star.line(to: NSPoint(x: point.x + 1.5, y: point.y - 1.5))
            star.line(to: NSPoint(x: point.x + r, y: point.y))
            star.line(to: NSPoint(x: point.x + 1.5, y: point.y + 1.5))
            star.line(to: NSPoint(x: point.x, y: point.y + r))
            star.line(to: NSPoint(x: point.x - 1.5, y: point.y + 1.5))
            star.line(to: NSPoint(x: point.x - r, y: point.y))
            star.line(to: NSPoint(x: point.x - 1.5, y: point.y - 1.5))
            star.close()
            NSColor(srgbRed: 0.85, green: 0.38, blue: 0.20, alpha: 1).setFill()
            star.fill()
        case .codex:
            let rect = NSRect(x: point.x - 6.5, y: point.y - 6.5, width: 13, height: 13)
            if let icon = AgentBadge.codexIcon {
                icon.draw(in: rect, from: NSRect(x: 142, y: 142, width: 740, height: 740),
                          operation: .sourceOver, fraction: 1, respectFlipped: true,
                          hints: [.interpolation: NSImageInterpolation.high.rawValue])
            } else {
                NSColor(srgbRed: 0.35, green: 0.42, blue: 1, alpha: 1).setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
        }
    }

    /// Three pixel z's drifting up and to the right off the top of the pet's
    /// head, each growing and fading in turn.
    func drawSnores(over rect: NSRect) {
        let glyph = ["SSSS", "..S.", ".S..", "SSSS"]
        let headTop = rect.minY + CGFloat(sheet.top) * Self.scale
        let startX = rect.midX + spriteSize * 0.15
        let period = 24 // 3 seconds per z
        // Anything rising past this line, a little above the head, is hidden.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSRect(x: 0, y: headTop - 32, width: bounds.width, height: bounds.height).clip()
        for k in 0..<3 {
            let t = CGFloat((tick + k * period / 3) % period) / CGFloat(period)
            // Far enough apart that neighbouring z's never touch.
            let pixel = (2 + t).rounded() // grows from 2pt to 3pt pixels
            let x = (startX + t * 33).rounded()
            let y = (headTop - 4 * pixel - 2 - t * 42).rounded()
            let alpha = t < 0.7 ? 1 : (1 - t) / 0.3
            iconColors["S"]?.withAlphaComponent(alpha).setFill()
            for (row, line) in glyph.enumerated() {
                for (col, key) in line.enumerated() where key == "S" {
                    NSRect(x: x + CGFloat(col) * pixel, y: y + CGFloat(row) * pixel,
                           width: pixel, height: pixel).fill()
                }
            }
        }
    }

    /// Where the Poké Ball sits: on the ground, centred where the pet stood.
    func ballRect(_ ball: CGImage?) -> NSRect {
        let size = CGFloat(ball?.width ?? 16) * Self.scale
        return NSRect(x: homeX + (spriteSize - size) / 2, y: Self.spriteTop + spriteSize - size,
                      width: size, height: size)
    }

    /// The CTX bar above the pet's head, while you hover over it or once its
    /// context has 20% or less remaining.
    func drawContextBarIfShown(headTop: CGFloat) {
        guard let remaining = contextLeft, hovering || remaining <= 0.2 else { return }
        drawContextBar(remaining: remaining, headTop: headTop)
    }

    /// A Gen 3 HP bar labelled CTX: it drains as the chat fills its context
    /// window, from green to yellow below half to red below a fifth.
    func drawContextBar(remaining rawRemaining: Double, headTop: CGFloat) {
        let px = max(1, (Self.scale * 4 / 3).rounded() / 2), width = 42, height = 7, track = 24 // 2 at medium
        let left = (homeX + spriteSize / 2 - CGFloat(width) * px / 2).rounded()
        let top = (headTop - 3 - CGFloat(height) * px).rounded()
        func fill(_ color: NSColor, _ x: Int, _ y: Int, _ w: Int = 1, _ h: Int = 1) {
            color.setFill()
            NSRect(x: left + CGFloat(x) * px, y: top + CGFloat(y) * px, width: CGFloat(w) * px, height: CGFloat(h) * px).fill()
        }

        // A dark capsule with rounded ends around a grey body.
        fill(ContextBar.outline, 1, 0, width - 2)
        fill(ContextBar.outline, 1, height - 1, width - 2)
        fill(ContextBar.outline, 0, 1, 1, height - 2)
        fill(ContextBar.outline, width - 1, 1, 1, height - 2)
        fill(ContextBar.body, 1, 1, width - 2, height - 2)
        // "CTX" where the HP label would be.
        for (i, glyph) in ContextBar.glyphs.enumerated() {
            for (row, line) in glyph.enumerated() {
                for (col, key) in line.enumerated() where key == "#" { fill(ContextBar.label, 2 + i * 4 + col, 1 + row) }
            }
        }
        // The white-edged track, filled with what's left.
        fill(ContextBar.border, 14, 1, track + 2, 5)
        fill(ContextBar.empty, 15, 2, track, 3)
        let remaining = max(0, min(1, rawRemaining))
        let filled = remaining > 0 ? max(1, Int((Double(track) * remaining).rounded())) : 0
        let (light, shade) = remaining > 0.5 ? ContextBar.green : remaining > 0.2 ? ContextBar.yellow : ContextBar.red
        if filled > 0 {
            fill(light, 15, 2, filled, 2)
            fill(shade, 15, 4, filled)
        }
    }

    /// Recall turns the pet red and shrinks it away to nothing where its ball
    /// would sit, as red sparkles close in; release pops it out of the ball in
    /// a white flash and sparkles. `progress` runs 0 → 1.
    func drawTransition(_ kind: Transition.Kind, progress p: CGFloat, ball: CGImage?) {
        let front = sheet.frames[0]
        let full = NSRect(x: homeX, y: Self.spriteTop, width: spriteSize, height: spriteSize)
        let ballFrame = ballRect(ball)

        switch kind {
        case .recall:
            let red = NSColor(srgbRed: 1, green: 0.2, blue: 0.2, alpha: 1)
            // A moment glowing red, then it shrinks, fading over the second half.
            let shrink = max(0, (p - 0.25) / 0.75)
            let size = (spriteSize * (1 - shrink) / Self.scale).rounded() * Self.scale
            let center = NSPoint(x: full.midX, y: full.midY + (ballFrame.midY - full.midY) * shrink)
            let rect = NSRect(x: (center.x - size / 2).rounded(), y: (center.y - size / 2).rounded(),
                              width: size, height: size)
            if size > 0 {
                drawTinted(front, in: rect, color: red, amount: min(1, 0.3 + p * 3), alpha: min(1, 2 - 2 * shrink))
            }
            if shrink > 0 {
                drawSparkles(around: NSRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16),
                             progress: 1 - shrink, color: red, alpha: 1 - shrink * 0.7)
            }
        case .release:
            let size = spriteSize * (0.3 + 0.7 * p)
            let rect = NSRect(x: full.midX - size / 2, y: full.maxY - size, width: size, height: size)
            drawTinted(front, in: rect, color: .white, amount: 1 - p)
            if p < 0.5 {
                if let ball { drawSprite(ball, in: ballFrame, mirrored: false) }
                drawSparkles(around: ballFrame, progress: p * 2)
            }
        }
    }

    /// The sprite washed with a colour, keeping its silhouette.
    func drawTinted(_ image: CGImage, in rect: NSRect, color: NSColor, amount: CGFloat, mirrored: Bool = false,
                    alpha: CGFloat = 1) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        drawSprite(image, in: rect, mirrored: mirrored)
        if amount > 0 {
            context.setBlendMode(.sourceAtop)
            context.setFillColor(color.withAlphaComponent(amount).cgColor)
            context.fill(rect)
        }
        context.endTransparencyLayer()
    }

    /// Eight pixel sparkles, `progress` of the way out from `rect`.
    func drawSparkles(around rect: NSRect, progress p: CGFloat, color: NSColor? = nil, alpha: CGFloat? = nil) {
        let s = Self.scale
        let distance = rect.width / 2 + p * 30
        (color ?? NSColor(srgbRed: 0.97, green: 0.82, blue: 0.25, alpha: 1))
            .withAlphaComponent(alpha ?? 1 - p * 0.6).setFill()
        for i in 0..<8 {
            let angle = CGFloat(i) * .pi / 4
            let x = ((rect.midX + cos(angle) * distance) / s).rounded() * s
            let y = ((rect.midY + sin(angle) * distance) / s).rounded() * s
            // A small pixel "+".
            NSRect(x: x - s, y: y, width: 3 * s, height: s).fill()
            NSRect(x: x, y: y - s, width: s, height: 3 * s).fill()
        }
    }

    func drawSprite(_ image: CGImage, in rect: NSRect, mirrored: Bool) {
        drawPixelSprite(image, in: rect, mirrored: mirrored)
    }

    /// A pixel-art shadow on the ground, on the sprite's own pixel grid: a 3-row
    /// oval `width` pixels across under a frame `pixels` wide, shrinking as the pet lifts off.
    func drawShadow(frame: NSRect, pixels: Int, width: Int, lift: CGFloat) {
        let s = Self.scale
        var w = Int((CGFloat(width) * (1 - lift / 50)).rounded())
        w -= w % 2 // stay centred on the frame
        guard w >= 6 else { return }
        let ground = Self.spriteTop + spriteSize // bottom of the resting frame
        NSColor(white: 0, alpha: 0.18).setFill()
        for (row, inset) in [2, 0, 2].enumerated() {
            let rowPixels = w - inset * 2
            NSRect(x: frame.minX + CGFloat((pixels - rowPixels) / 2) * s,
                   y: ground - CGFloat(3 - row) * s,
                   width: CGFloat(rowPixels) * s, height: s).fill()
        }
    }

    // MARK: Mouse

    var dragStart: NSPoint?
    var windowStart: NSPoint?
    var dragged = false
    var draggingAll = false

    /// The frames its current pose flips between, and whether they're drawn
    /// mirrored, as draw(_:) picks them.
    var pose: (frames: [Int], mirrored: Bool) {
        if mood == .working && spinsWhileWorking {
            return (Array(sheet.frames.indices.prefix(min(8, sheet.frames.count))), false)
        }
        guard walkX != 0 || mood == .working else { return ([0, 1], false) }
        let right = walkDirection > 0
        if right && sheet.frames.count >= 8 { return ([6, 7], false) }
        return ([4, 5], right)
    }

    /// The only part of the window that hovers and clicks: the tightest
    /// rectangle around the pet's visible pixels in the pose it's in, where it
    /// stands (hops don't move it, so it doesn't jump out from under the mouse).
    var hitBox: NSRect {
        let (frames, mirrored) = pose
        let width = CGFloat(sheet.frames[0].width)
        let box = frames.map { sheet.boxes[$0] }.filter { !$0.isEmpty }.reduce(CGRect.null) { $0.union($1) }
        guard !box.isNull else { return .zero }
        let left = mirrored ? width - box.maxX : box.minX
        return NSRect(x: homeX + walkX + left * Self.scale, y: Self.spriteTop + box.minY * Self.scale,
                      width: box.width * Self.scale, height: box.height * Self.scale)
    }
    /// The hit box on screen, for AppDelegate.trackMouse().
    var screenHitBox: NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(hitBox, to: nil))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return hitBox.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        windowStart = window?.frame.origin
        dragged = false
        draggingAll = event.modifierFlags.contains(.shift)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let windowStart, let window else { return }
        let now = NSEvent.mouseLocation
        let offset = NSPoint(x: now.x - dragStart.x, y: now.y - dragStart.y)
        if hypot(offset.x, offset.y) > 3 { dragged = true }
        guard dragged else { return }
        if draggingAll {
            onDragAll?(offset)
        } else {
            window.setFrameOrigin(NSPoint(x: windowStart.x + offset.x, y: windowStart.y + offset.y))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragged { clicked() } else if draggingAll { onDragAll?(nil) } else { onMoved?(self) }
        dragStart = nil
    }

    /// Lets the pet out (or wakes it), then jumps to its agent.
    func clicked() {
        finishedAt = nil
        hopUntil = Date().addingTimeInterval(0.6)
        wake()
        focus(agent)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "\(name) · \(agent.status)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let detail = NSMenuItem(title: agent.label, action: nil, keyEquivalent: "")
        detail.isEnabled = false
        menu.addItem(detail)
        let provider = NSMenuItem(title: "Agent · \(agent.kind.rawValue)", action: nil, keyEquivalent: "")
        provider.isEnabled = false
        menu.addItem(provider)
        menu.addItem(.separator())

        let go = NSMenuItem(title: "Go to Agent", action: #selector(goToAgent), keyEquivalent: "")
        go.target = self
        menu.addItem(go)

        let ball = NSMenuItem(title: "Return to Poké Ball", action: #selector(returnToBall), keyEquivalent: "")
        ball.target = self
        // A busy agent would pop it straight back out.
        ball.isEnabled = mood != .working && mood != .alert
        menu.addItem(ball)
        // Let Out ▸ each pet resting out of sight.
        let resting = restingPets?() ?? []
        if !resting.isEmpty {
            let out = NSMenuItem(title: "Let Out", action: nil, keyEquivalent: "")
            let list = NSMenu()
            for pet in resting {
                let item = NSMenuItem(title: "\(pet.name) · \(pet.agent.label)", action: #selector(wake), keyEquivalent: "")
                item.target = pet
                list.addItem(item)
            }
            out.submenu = list
            menu.addItem(out)
        }

        let choose = NSMenuItem(title: "Pokémon", action: nil, keyEquivalent: "")
        let choices = NSMenu()
        choices.autoenablesItems = false
        for generation in PokemonCatalog.generations {
            let region = NSMenuItem(title: generation.title, action: nil, keyEquivalent: "")
            let picker = NSMenu()
            picker.autoenablesItems = false
            let grid = NSMenuItem()
            grid.view = PokemonPickerView(names: PokemonCatalog.names(in: generation.range),
                                          current: pokemon, taken: otherPokemon?() ?? []) { [weak self] name in
                guard let self else { return }
                self.onChoosePokemon?(self, name)
            }
            picker.addItem(grid)
            region.submenu = picker
            choices.addItem(region)
        }
        choose.submenu = choices
        menu.addItem(choose)

        menu.addItem(.separator())
        // Line Up Pets ▸ Vertical / Horizontal, then the four corners. Picking
        // any of them lines the pets up again, undoing drags.
        let lineUp = NSMenuItem(title: "Line Up Pets", action: nil, keyEquivalent: "")
        let arrange = NSMenu()
        arrange.autoenablesItems = false
        let current = Arrangement.saved
        for (title, vertical) in [("Vertical", true), ("Horizontal", false)] {
            let item = NSMenuItem(title: title, action: #selector(setDirection(_:)), keyEquivalent: "")
            item.target = self
            item.tag = vertical ? 1 : 0
            item.state = current.vertical == vertical ? .on : .off
            arrange.addItem(item)
        }
        arrange.addItem(.separator())
        for corner in Arrangement.Corner.allCases {
            let item = NSMenuItem(title: corner.title, action: #selector(setCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = corner.rawValue
            item.state = current.corner == corner ? .on : .off
            arrange.addItem(item)
        }
        lineUp.submenu = arrange
        menu.addItem(lineUp)
        if (ClaudeApp.installed || Conductor.installed) && !AXIsProcessTrusted() {
            let allow = NSMenuItem(title: "Enable Chat Switching…", action: #selector(allowClaudeApp), keyEquivalent: "")
            allow.target = self
            menu.addItem(allow)
        }
        let size = NSMenuItem()
        size.view = SizeSlider(value: PetSize.saved) { [weak self] value in self?.onSize?(value) }
        menu.addItem(size)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Pet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        // Pinned to the screen where you clicked, not to this window: the Size
        // slider moves the windows, and a menu attached to one would move too,
        // sliding the slider out from under the mouse.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc func goToAgent() { clicked() }
    @objc func allowClaudeApp() {
        ClaudeApp.askForAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func setDirection(_ sender: NSMenuItem) {
        Arrangement.saved.vertical = sender.tag == 1
        lineUpHere()
    }

    @objc func setCorner(_ sender: NSMenuItem) {
        guard let corner = (sender.representedObject as? String).flatMap(Arrangement.Corner.init) else { return }
        Arrangement.saved.corner = corner
        lineUpHere()
    }

    /// Lines everyone up again on the display this pet is on.
    func lineUpHere() {
        if let screen = window?.screen { Arrangement.saved.display = screen.displayID }
        onLineUp?()
    }
}

// MARK: - Size slider

/// The Size row in the right-click menu: a slider from Small to Large that
/// holds briefly at Small, Medium and Large (with a tick on a Force Touch
/// trackpad), resizing the pets as it moves.
final class SizeSlider: NSView {
    let slider: NSSlider
    let onChange: (CGFloat) -> Void
    var held: CGFloat?

    init(value: CGFloat, onChange: @escaping (CGFloat) -> Void) {
        self.onChange = onChange
        slider = NSSlider(value: Double(value), minValue: Double(PetSize.small), maxValue: Double(PetSize.large),
                          target: nil, action: nil)
        held = PetSize.locks.contains(value) ? value : nil
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 62))

        let title = NSTextField(labelWithString: "Size")
        title.font = .menuFont(ofSize: 0)
        title.frame = NSRect(x: 21, y: 4, width: 200, height: 18)
        addSubview(title)

        slider.numberOfTickMarks = PetSize.locks.count
        slider.allowsTickMarkValuesOnly = false
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(moved)
        slider.frame = NSRect(x: 20, y: 22, width: 200, height: 24)
        addSubview(slider)

        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        for (text, alignment) in [("Small", NSTextAlignment.left), ("Medium", .center), ("Large", .right)] {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = .secondaryLabelColor
            label.alignment = alignment
            label.frame = NSRect(x: 20, y: 44, width: 200, height: 14)
            addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    @objc func moved() {
        let raw = CGFloat(slider.doubleValue)
        let value = PetSize.settle(raw)
        if value != raw { slider.doubleValue = Double(value) }
        let lock = PetSize.locks.contains(value) ? value : nil
        if let lock, lock != held { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
        held = lock
        onChange(value)
    }
}

// MARK: - Pokémon picker

/// A generation can contain more Pokémon than fit on screen, so each region's
/// grid lives in a compact scrolling submenu.
final class PokemonPickerView: NSView {
    init(names: [String], current: String, taken: Set<String>, onPick: @escaping (String) -> Void) {
        let grid = PokemonGrid(names: names, current: current, taken: taken, onPick: onPick)
        let viewport = NSSize(width: grid.frame.width + 14, height: min(grid.frame.height, 520))
        super.init(frame: NSRect(origin: .zero, size: viewport))
        let scroll = NSScrollView(frame: bounds)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = grid.frame.height > viewport.height
        scroll.autohidesScrollers = true
        scroll.documentView = grid
        scroll.contentView.scroll(to: .zero)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Every Pokémon as its sprite in a grid, shown in the right-click menu. The
/// current one is highlighted, ones other agents have are faded (picking one
/// swaps), and the hovered one walks in place.
final class PokemonGrid: NSView {
    static let columns = 8
    static let cell = NSSize(width: 68, height: 84)
    static let padding: CGFloat = 8

    let names: [String]
    let current: String
    let taken: Set<String>
    let onPick: (String) -> Void
    var hovered: Int?
    var step = 0
    var timer: Timer?

    init(names: [String] = roster, current: String, taken: Set<String>, onPick: @escaping (String) -> Void) {
        self.names = names.filter { SpriteSheet.named($0) != nil }
        self.current = current
        self.taken = taken
        self.onPick = onPick
        let rows = (self.names.count + Self.columns - 1) / Self.columns
        super.init(frame: NSRect(x: 0, y: 0,
                                 width: CGFloat(Self.columns) * Self.cell.width + 2 * Self.padding,
                                 height: CGFloat(rows) * Self.cell.height + 2 * Self.padding))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func cellRect(_ i: Int) -> NSRect {
        NSRect(x: Self.padding + CGFloat(i % Self.columns) * Self.cell.width,
               y: Self.padding + CGFloat(i / Self.columns) * Self.cell.height,
               width: Self.cell.width, height: Self.cell.height)
    }

    func index(at event: NSEvent) -> Int? {
        let point = convert(event.locationInWindow, from: nil)
        return names.indices.first { cellRect($0).contains(point) }
    }

    /// Steps the hovered sprite, in the menu's run loop mode so it moves while the menu is open.
    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.hovered != nil else { return }
                self.step += 1
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) { setHovered(index(at: event)) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    func setHovered(_ i: Int?) {
        guard i != hovered else { return }
        hovered = i
        step = 0
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let i = index(at: event) else { return }
        var menu = enclosingMenuItem?.menu
        while let parent = menu?.supermenu { menu = parent }
        menu?.cancelTracking()
        onPick(names[i])
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        for (i, name) in names.enumerated() {
            guard let sheet = SpriteSheet.named(name) else { continue }
            let cell = cellRect(i).insetBy(dx: 2, dy: 2)
            if name == current {
                NSColor.controlAccentColor.withAlphaComponent(0.3).setFill()
                NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6).fill()
            } else if i == hovered {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: cell, xRadius: 6, yRadius: 6).fill()
            }

            let frame = i == hovered ? sheet.frames[step % 2] : sheet.frames[0]
            // Some 64-pixel sheets contain a normal-sized sprite surrounded by
            // transparent padding. Fit the visible artwork, not the raw frame,
            // so those Pokémon remain as large as their 32-pixel neighbours.
            let box = sheet.boxes[i == hovered ? step % 2 : 0]
            let visibleSize = max(box.width, box.height)
            let previewScale = visibleSize > 0 ? min(2, 58 / visibleSize) : 1
            let size = CGFloat(frame.width) * previewScale
            let sprite = NSRect(x: cell.midX - box.midX * previewScale,
                                y: cell.minY + 31 - box.midY * previewScale,
                                width: size, height: size)
            let inUse = taken.contains(name)
            drawPixelSprite(frame, in: sprite, alpha: inUse ? 0.4 : 1)

            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: inUse ? NSColor.tertiaryLabelColor : NSColor.labelColor,
            ]
            let label = PokemonCatalog.displayName(for: name) as NSString
            let width = label.size(withAttributes: attrs).width
            label.draw(at: NSPoint(x: cell.midX - width / 2, y: cell.minY + 64), withAttributes: attrs)
        }
    }
}

// MARK: - Lining up

/// Bottom corners start just above Claude Code's prompt box at the bottom of the terminal.
let stackBase: CGFloat = 92
/// Top corners keep heads this far below the menu bar.
let stackTop: CGFloat = 24
/// Clear space between the bottom of a pet's caption room and the topmost pixel of the pet below it.
let stackGap: CGFloat = 8
/// Room between the sprites and the screen's side edge.
let stackMargin: CGFloat = 16

/// How the pets line up: a column or a row, tucked into one corner of the screen.
struct Arrangement {
    enum Corner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var title: String {
            ["topLeft": "Top Left", "topRight": "Top Right", "bottomLeft": "Bottom Left", "bottomRight": "Bottom Right"][rawValue]!
        }
    }

    var vertical = true
    var corner = Corner.bottomRight
    /// How far the whole line-up has been Shift-dragged from its corner.
    var offset = NSPoint.zero
    /// The display it's on, once it has been Shift-dragged onto one; until
    /// then (or while that display is unplugged), the one with the menu bar.
    var display: CGDirectDisplayID?
    var onLeft: Bool { corner == .topLeft || corner == .bottomLeft }
    var atTop: Bool { corner == .topLeft || corner == .topRight }

    /// The choice from the right-click menu, kept across restarts.
    static var saved: Arrangement {
        get {
            let defaults = UserDefaults.standard
            return Arrangement(vertical: defaults.string(forKey: "lineUp.direction") != "horizontal",
                               corner: Corner(rawValue: defaults.string(forKey: "lineUp.corner") ?? "") ?? .bottomRight,
                               offset: defaults.string(forKey: "lineUp.offset").map(NSPointFromString) ?? .zero,
                               display: (defaults.object(forKey: "lineUp.display") as? NSNumber)?.uint32Value)
        }
        set {
            UserDefaults.standard.set(newValue.vertical ? "vertical" : "horizontal", forKey: "lineUp.direction")
            UserDefaults.standard.set(newValue.corner.rawValue, forKey: "lineUp.corner")
            UserDefaults.standard.set(NSStringFromPoint(newValue.offset), forKey: "lineUp.offset")
            UserDefaults.standard.set(newValue.display.map { NSNumber(value: $0) }, forKey: "lineUp.display")
        }
    }

    /// The screen it's on. Not NSScreen.main, which is whichever screen you're
    /// working on and would send the line-up hopping between displays.
    var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == display } ?? NSScreen.screens.first
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

/// Where each pet's window goes, lined up in `arrangement` within `visible` in
/// `pets` order: top to bottom in a column, left to right in a row.
///
/// In a column each pet's ground sits its caption room plus the gap above the
/// head of the one below, and every pet shares a centre line regardless of its
/// canvas size. The gap shrinks if they won't fit. In a row they share one ground line.
func stackOrigins(_ pets: [PetView], in visible: NSRect, arrangement: Arrangement) -> [NSPoint] {
    guard !pets.isEmpty else { return [] }
    let onLeft = arrangement.onLeft
    let heights = pets.map(\.visibleHeight)
    // The window's x that puts the pet's sprite with its left edge at `left`.
    func panelX(_ pet: PetView, spriteLeft left: CGFloat) -> CGFloat { left - pet.homeX }

    guard arrangement.vertical else {
        // Centre to centre, neighbours sit the gap apart at their widest (a Poké
        // Ball takes far less room than a Pokémon). Squeezed evenly if the row
        // won't fit.
        let widths = pets.map(\.footprintWidth)
        var steps = (0..<pets.count - 1).map { widths[$0] / 2 + stackGap + widths[$0 + 1] / 2 }
        let available = visible.width - 2 * stackMargin - pets[0].spriteSize
        let total = steps.reduce(0, +)
        if total > available { steps = steps.map { $0 * available / total } }

        // The row starts in the chosen corner: the first pet on the left, or the last on the right.
        var centers = [onLeft ? visible.minX + stackMargin + pets[0].spriteSize / 2
                              : visible.maxX - stackMargin - pets[0].spriteSize / 2 - steps.reduce(0, +)]
        for step in steps { centers.append(centers.last! + step) }

        let ground = arrangement.atTop ? visible.maxY - stackTop - heights.max()! : visible.minY + stackBase + 4
        return zip(pets, centers).map { pet, center in
            NSPoint(x: panelX(pet, spriteLeft: center - pet.spriteSize / 2), y: ground - PetView.bottomPad)
        }
    }

    let room = visible.height - stackBase - stackTop - heights.reduce(0, +) - CGFloat(pets.count) * PetView.captionDepth
    // Too tall for the screen even with no gap: they close up and overlap a little rather than run off it.
    let gap = pets.count > 1 ? min(stackGap, room / CGFloat(pets.count - 1)) : 0
    // Reserve the widest visible footprint, including pacing, so larger sheets
    // share the same centre as smaller ones without spilling over the screen edge.
    let halfWidth = pets.map(\.footprintWidth).max()! / 2
    let centerX = onLeft ? visible.minX + stackMargin + halfWidth : visible.maxX - stackMargin - halfWidth
    let x = { (pet: PetView) in panelX(pet, spriteLeft: centerX - pet.spriteSize / 2) }

    var origins: [NSPoint] = []
    if arrangement.atTop {
        // Top down from just under the menu bar.
        var ground = visible.maxY - stackTop - heights[0]
        for (i, pet) in pets.enumerated() {
            origins.append(NSPoint(x: x(pet), y: ground - PetView.bottomPad))
            if i + 1 < pets.count { ground -= PetView.captionDepth + gap + heights[i + 1] }
        }
    } else {
        // Bottom up from just above the prompt box.
        var ground = visible.minY + stackBase + 4
        for pet in pets.reversed() {
            origins.append(NSPoint(x: x(pet), y: ground - PetView.bottomPad))
            ground += pet.visibleHeight + gap + PetView.captionDepth // the next pet's caption room
        }
        origins.reverse()
    }
    return origins
}

/// Moves a line-up back onto the screen if any of it spills past an edge (it
/// grew, or was Shift-dragged too far), keeping its shape: everything shifts
/// the other way by just as much as it overhangs.
func keepOnScreen(_ pets: [PetView], _ origins: [NSPoint], in visible: NSRect) -> [NSPoint] {
    guard !pets.isEmpty else { return origins }
    // What each one covers: from the top of its head down to its caption, as wide as it reaches.
    let covered = zip(pets, origins).map { pet, origin -> NSRect in
        let ground = origin.y + PetView.bottomPad
        let middle = origin.x + pet.homeX + pet.spriteSize / 2
        return NSRect(x: middle - pet.footprintWidth / 2, y: ground - PetView.captionDepth,
                      width: pet.footprintWidth, height: pet.visibleHeight + PetView.captionDepth)
    }
    let all = covered.dropFirst().reduce(covered[0]) { $0.union($1) }
    var dx: CGFloat = 0, dy: CGFloat = 0
    if all.minX < visible.minX { dx = visible.minX - all.minX } else if all.maxX > visible.maxX { dx = visible.maxX - all.maxX }
    // If it's taller than the screen, keep the top on it.
    if all.maxY > visible.maxY { dy = visible.maxY - all.maxY } else if all.minY < visible.minY { dy = visible.minY - all.minY }
    return origins.map { NSPoint(x: $0.x + dx, y: $0.y + dy) }
}

// MARK: - App

/// The menu bar icon: a Poké Ball, its top half solid and its bottom half
/// open, split by a band with the button in the middle. A template image, so
/// it matches the menu bar in light and dark mode.
func menuBarBall() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let centre = NSPoint(x: 9, y: 9), radius: CGFloat = 7.25
        func circle(_ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: centre.x - r, y: centre.y - r, width: 2 * r, height: 2 * r))
        }
        func erase(_ draw: () -> Void) {
            NSGraphicsContext.current?.compositingOperation = .clear
            draw()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        }
        NSColor.black.set()
        let top = NSBezierPath()
        top.appendArc(withCenter: centre, radius: radius, startAngle: 0, endAngle: 180)
        top.close()
        top.fill()
        let ring = circle(radius - 0.75)
        ring.lineWidth = 1.5
        ring.stroke()
        // A thin gap under the solid top, then the band across the middle.
        erase { NSRect(x: centre.x - radius + 1.5, y: centre.y + 0.75, width: 2 * radius - 3, height: 1).fill() }
        NSRect(x: 1.75, y: centre.y - 0.75, width: 14.5, height: 1.5).fill()
        // The button: a ring in a cleared circle.
        erase { circle(3.5).fill() }
        let button = circle(2.25)
        button.lineWidth = 1.5
        button.stroke()
        return true
    }
    image.isTemplate = true
    return image
}

/// A Poké Ball's flight from just off the side of the screen onto the spot
/// where a pet comes out: from the right edge for a pet on the right half of
/// the screen, the left otherwise. One high arc, spinning, then a small bounce.
struct BallThrow {
    let start: NSPoint, end: NSPoint // the ball's bottom-left corner, on screen
    let arc: CGFloat
    let duration: CFTimeInterval
    let fromRight: Bool
    /// The arc's share of the flight; the bounce takes the rest.
    static let arcShare: CGFloat = 0.82

    init(onto landing: NSRect, screen: NSRect, visible: NSRect) {
        fromRight = landing.midX > screen.midX
        let top = visible.maxY - landing.height // under the menu bar
        start = NSPoint(x: fromRight ? screen.maxX + 2 : screen.minX - landing.width - 2,
                        y: min(landing.minY + 40, top))
        end = landing.origin
        let distance = abs(end.x - start.x)
        arc = max(0, min(max(90, distance * 0.3), 200, top - max(start.y, end.y)))
        duration = min(1.1, 0.65 + distance / 2000)
    }

    /// Where the ball is `t` (0 to 1) through its flight, and how many quarter
    /// turns it has spun clockwise (rolling the way it's going), upright again
    /// once it lands.
    func position(at t: CGFloat) -> (origin: NSPoint, quarterTurns: Int) {
        if t < Self.arcShare {
            let u = t / Self.arcShare
            let point = NSPoint(x: start.x + (end.x - start.x) * u,
                                y: start.y + (end.y - start.y) * u + arc * 4 * u * (1 - u))
            let turns = Int(Double(t) * duration / 0.07)
            return (NSPoint(x: point.x.rounded(), y: point.y.rounded()), fromRight ? -turns : turns)
        }
        let u = (t - Self.arcShare) / (1 - Self.arcShare)
        return (NSPoint(x: end.x, y: (end.y + 12 * 4 * u * (1 - u)).rounded()), 0)
    }
}

/// Draws the Poké Ball turned by quarter turns clockwise in a flipped view,
/// keeping its pixels square.
func drawBall(_ ball: CGImage, in rect: NSRect, quarterTurns: Int) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.saveGState()
    context.translateBy(x: rect.midX, y: rect.midY)
    context.rotate(by: CGFloat(quarterTurns) * .pi / 2)
    context.translateBy(x: -rect.midX, y: -rect.midY)
    drawPixelSprite(ball, in: rect)
    context.restoreGState()
}

/// The thrown ball, in a window spanning its whole flight.
final class BallThrowView: NSView {
    let ball: CGImage
    var ballRect = NSRect.zero
    var quarterTurns = 0

    init(ball: CGImage, frame: NSRect) {
        self.ball = ball
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        drawBall(ball, in: ballRect, quarterTurns: quarterTurns)
    }
}

/// Borderless panels can't normally take clicks without stealing focus; these never become key.
final class PetPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Lets a window hang past the screen edges and behind the menu bar. Pets
    /// sit in the middle of mostly empty windows (room for jumps and captions),
    /// and macOS would otherwise push a window at the edge onto its neighbour.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Hide Pets in the menu bar: every pet stays out of sight until Show Pets.
    static var allHidden: Bool {
        get { UserDefaults.standard.bool(forKey: "hidden") }
        set { UserDefaults.standard.set(newValue, forKey: "hidden") }
    }
    private var wantsShown = true
    /// Whether the mouse is over its pet's hit box. Only then does it take
    /// clicks: a window that takes any takes them everywhere, clear parts and
    /// all, covering whatever is under the empty room around its pet.
    var mouseOver = false {
        didSet { if mouseOver != oldValue { refreshShown() } }
    }

    /// Shows or hides it without taking it off screen. A window taken off and
    /// put back lands on only the Space you're on at the time, not all of them.
    func setShown(_ shown: Bool) {
        wantsShown = shown
        let visible = shown && !Self.allHidden
        alphaValue = visible ? 1 : 0
        ignoresMouseEvents = !(visible && mouseOver)
    }

    /// Catches up with Hide Pets or Show Pets.
    func refreshShown() { setShown(wantsShown) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var pets: [String: PetView] = [:]      // by herdr pane
    var panels: [String: PetPanel] = [:]
    /// Panes in herdr's agent order, which matches its sidebar top to bottom.
    var order: [String] = []
    /// Panels already on screen, which slide to new spots instead of jumping.
    var placed: Set<ObjectIdentifier> = []
    var polling = false
    let defaults = UserDefaults.standard
    var statusItem: NSStatusItem?

    /// Which Pokémon each herdr pane gets, kept across restarts.
    var assignments: [String: String] {
        get { defaults.dictionary(forKey: "assignments") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "assignments") }
    }
    /// Where each Pokémon was dragged to; pets without one line up in the corner.
    var positions: [String: String] {
        get { defaults.dictionary(forKey: "positions") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "positions") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ClaudeApp.askForAccessIfNeeded()
        setUpMenuBar()
        // In .common mode so pets keep moving while a right-click menu is open.
        let animation = Timer(timeInterval: 0.125, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pets.values.forEach { $0.animate() }
                self?.trackMouse() // pets walk under a mouse that's still
            }
        }
        watchMouse()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
        let polling = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(animation, forMode: .common)
        RunLoop.main.add(polling, forMode: .common)
        poll()
    }

    func poll() {
        guard !polling else { return }
        polling = true
        DispatchQueue.global().async {
            let agents = currentAgents()
            DispatchQueue.main.async {
                self.polling = false
                self.sync(agents)
            }
        }
    }

    /// Adds a pet for each new agent and removes pets whose agents have gone.
    func sync(_ agents: [Agent]) {
        var changed = false
        if agents.map(\.pane) != order {
            order = agents.map(\.pane)
            changed = true
        }
        let live = Set(order)
        for pane in pets.keys where !live.contains(pane) {
            if let panel = panels[pane] {
                panel.orderOut(nil)
                placed.remove(ObjectIdentifier(panel))
            }
            panels[pane] = nil
            pets[pane] = nil
            changed = true
        }
        for agent in agents {
            if let pet = pets[agent.pane] {
                pet.update(agent)
                continue
            }
            guard let name = pokemon(for: agent.pane), let sheet = SpriteSheet.named(name) else { continue }
            let pet = PetView(agent: agent, pokemon: name, sheet: sheet)
            pet.onMoved = { [weak self] pet in
                guard let origin = pet.window?.frame.origin else { return }
                self?.positions[pet.pokemon] = NSStringFromPoint(origin)
            }
            pet.onChoosePokemon = { [weak self] pet, name in self?.choose(name, for: pet) }
            pet.onDragAll = { [weak self] offset in self?.dragAll(by: offset) }
            pet.onLineUp = { [weak self] in
                self?.positions = [:]
                Arrangement.saved.offset = .zero
                self?.layout()
            }
            pet.onVanish = { [weak self] in self?.layout() }
            pet.onSize = { [weak self] value in self?.resize(to: value) }
            pet.onSummon = { [weak self] pet in self?.summon(pet) }
            pet.restingPets = { [weak self] in
                guard let self else { return [] }
                return self.order.compactMap { self.pets[$0] }.filter(\.isGone)
            }
            pet.otherPokemon = { [weak self, weak pet] in
                Set(self?.pets.values.filter { $0 !== pet }.map(\.pokemon) ?? [])
            }
            pet.update(agent)
            pets[agent.pane] = pet
            panels[agent.pane] = makePanel(for: pet)
            changed = true
        }
        if changed { layout() }
    }

    /// The pane's Pokémon from last time, or a random one no live pet is using.
    func pokemon(for pane: String) -> String? {
        let taken = Set(pets.values.map(\.pokemon))
        if let name = assignments[pane], !taken.contains(name), SpriteSheet.named(name) != nil {
            return name
        }
        let available = roster.filter { !taken.contains($0) && SpriteSheet.named($0) != nil }
        guard let name = available.randomElement() ?? roster.first(where: { SpriteSheet.named($0) != nil })
        else { return nil }
        assignments[pane] = name
        return name
    }

    /// Gives a pet a new Pokémon, swapping with any live pet that already has it.
    func choose(_ name: String, for pet: PetView) {
        guard let sheet = SpriteSheet.named(name), name != pet.pokemon else { return }
        let previous = pet.pokemon
        if let other = pets.values.first(where: { $0 !== pet && $0.pokemon == name }),
           let previousSheet = SpriteSheet.named(previous) {
            other.setPokemon(previous, sheet: previousSheet)
            assignments[other.agent.pane] = previous
        }
        pet.setPokemon(name, sheet: sheet)
        assignments[pet.agent.pane] = name
        layout() // the new Pokémon may be taller or shorter
    }

    func makePanel(for pet: PetView) -> PetPanel {
        let panel = PetPanel(contentRect: pet.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none // it comes and goes with its own animations
        panel.contentView = pet
        panel.acceptsMouseMovedEvents = true // so trackMouse() hears the mouse leave it
        panel.orderFrontRegardless()
        panel.setShown(!pet.isGone)
        return panel
    }

    /// Pets coming back out this round, thrown in together once all have room.
    var summoning: [PetView] = []

    /// Brings a resting pet back, along with any others coming out at the same time.
    func summon(_ pet: PetView) {
        summoning.append(pet)
        guard summoning.count == 1 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pets = summoning
            summoning = []
            layout() // makes room for them all first, so none moves once its ball is in the air
            pets.forEach(throwBall)
        }
    }

    /// Throws a pet's Poké Ball in from the side of the screen it's on; the pet
    /// comes out where it lands.
    func throwBall(for pet: PetView) {
        guard let panel = panels[pet.agent.pane], panel.contentView === pet else { return pet.land() }
        panel.setShown(true)
        panel.orderFrontRegardless()
        // While hidden, a ball would fly across the screen with no pet to land.
        if PetPanel.allHidden { return pet.land() }
        let landing = panel.convertToScreen(pet.convert(pet.ballRect(pokeball), to: nil))
        guard let ball = pokeball,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: landing.midX, y: landing.midY)) })
                ?? NSScreen.main else { return pet.land() }
        let flight = BallThrow(onto: landing, screen: screen.frame, visible: screen.visibleFrame)

        // A window spanning the whole flight, from just off the edge to the landing spot.
        let span = NSRect(x: min(flight.start.x, flight.end.x), y: min(flight.start.y, flight.end.y),
                          width: abs(flight.end.x - flight.start.x) + landing.width,
                          height: abs(flight.end.y - flight.start.y) + flight.arc + 16 + landing.height)
        let window = PetPanel(contentRect: span, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none // no zoom in or fade out, which would blur the pixels
        window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = BallThrowView(ball: ball, frame: NSRect(origin: .zero, size: span.size))
        window.contentView = view

        func show(_ t: CGFloat) {
            let (origin, turns) = flight.position(at: t)
            // The view is flipped: measured down from the window's top.
            view.ballRect = NSRect(x: origin.x - span.minX, y: span.maxY - origin.y - landing.height,
                                   width: landing.width, height: landing.height)
            view.quarterTurns = turns
            view.needsDisplay = true
        }
        show(0)
        window.orderFrontRegardless()
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                let t = min(1, CGFloat((CACurrentMediaTime() - began) / flight.duration))
                show(t)
                guard t >= 1 else { return }
                timer.invalidate()
                // The pet draws its ball on the same spot, then pops out of it.
                pet.land()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { window.orderOut(nil) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Where a pet was dragged to, if it's still on a screen: judged by the
    /// middle of the pet, since its window hangs well past it on every side.
    func draggedSpot(of pet: PetView) -> NSPoint? {
        guard let point = positions[pet.pokemon].map(NSPointFromString) else { return nil }
        let middle = NSPoint(x: point.x + pet.frame.width / 2, y: point.y + PetView.bottomPad + pet.visibleHeight / 2)
        return NSScreen.screens.contains { $0.frame.contains(middle) } ? point : nil
    }

    /// Where each visible pet's window was when a Shift-drag began, and how far it has gone.
    var groupDrag: (start: [String: NSPoint], offset: NSPoint)?

    /// Moves every visible pet with a Shift-drag. When it's let go, the line-up
    /// keeps its new spot (pets coming and going still line up there), and pets
    /// dragged off on their own keep theirs, moved by the same amount.
    func dragAll(by offset: NSPoint?) {
        guard let offset else {
            guard let drag = groupDrag else { return }
            groupDrag = nil
            var arrangement = Arrangement.saved
            arrangement.offset.x += drag.offset.x
            arrangement.offset.y += drag.offset.y
            // Let go on another display, the line-up moves to it, staying where it was dropped.
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
               screen != arrangement.screen {
                let stacked = order.compactMap { pets[$0] }.filter { !$0.isGone && draggedSpot(of: $0) == nil }
                if let first = stacked.first, let start = drag.start[first.agent.pane] {
                    var moved = arrangement
                    moved.display = screen.displayID
                    moved.offset = .zero
                    let corner = stackOrigins(stacked, in: screen.visibleFrame, arrangement: moved)[0]
                    moved.offset = NSPoint(x: start.x + drag.offset.x - corner.x, y: start.y + drag.offset.y - corner.y)
                    arrangement = moved
                }
            }
            Arrangement.saved = arrangement
            var saved = positions
            for (pane, start) in drag.start {
                guard let pet = pets[pane], saved[pet.pokemon] != nil else { continue }
                saved[pet.pokemon] = NSStringFromPoint(NSPoint(x: start.x + drag.offset.x, y: start.y + drag.offset.y))
            }
            positions = saved
            layout()
            return
        }
        let start = groupDrag?.start ?? panels.filter { pets[$0.key]?.isGone == false }.mapValues(\.frame.origin)
        groupDrag = (start, offset)
        for (pane, origin) in start {
            panels[pane]?.setFrameOrigin(NSPoint(x: origin.x + offset.x, y: origin.y + offset.y))
        }
    }

    /// Resizes every pet for the Size slider, keeping each one's feet where they were.
    func resize(to value: CGFloat) {
        PetSize.saved = value
        let scale = PetSize.scale(for: value)
        guard scale != PetView.scale else { return }
        PetView.scale = scale
        for pet in pets.values { pet.fitSize() }
        layout(animated: false) // follows the slider as it moves
    }

    /// Puts dragged pets where they were left, and lines the rest up in agent
    /// order as chosen under Line Up Pets (by default a column in the bottom-right corner).
    func layout(animated: Bool = true) {
        let arrangement = Arrangement.saved
        let visible = arrangement.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var stack: [(pet: PetView, panel: PetPanel)] = []
        for pane in order {
            guard let pet = pets[pane], let panel = panels[pane] else { continue }
            pet.captionAbove = false
            if pet.isGone {
                // Out of sight, taking no room; it's put straight in place when it comes back.
                panel.setShown(false)
                placed.remove(ObjectIdentifier(panel))
                continue
            }
            if let point = draggedSpot(of: pet) {
                move(panel, to: point, animated: animated)
                panel.setShown(true)
            } else {
                stack.append((pet, panel))
            }
        }
        for (i, item) in stack.enumerated() {
            item.pet.pace = arrangement.vertical ? PetView.columnPace : PetView.rowPace
            item.pet.captionAbove = !arrangement.vertical && i % 2 == 1
        }
        // Last first, each ordered in front of the next, so in a column a pet's
        // caption covers the z's rising from the one below, and they pass behind it.
        var origins = stackOrigins(stack.map(\.pet), in: visible, arrangement: arrangement)
            .map { NSPoint(x: $0.x + arrangement.offset.x, y: $0.y + arrangement.offset.y) }
        origins = keepOnScreen(stack.map(\.pet), origins, in: visible)
        for ((_, panel), origin) in zip(stack, origins).reversed() {
            move(panel, to: origin, animated: animated)
            panel.setShown(true)
            panel.orderFrontRegardless()
        }
    }

    // MARK: Mouse

    /// Watches the mouse everywhere, since a pet's window lets it through
    /// until it's over the pet (see PetPanel.mouseOver).
    func watchMouse() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                           .leftMouseUp, .rightMouseUp]
        NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.trackMouse()
            return event
        }
    }

    /// The pet whose hit box the mouse is in takes clicks and shows it's
    /// hovered; every other window lets them through. Where boxes overlap, the
    /// one in front wins: line-ups put earlier pets in front. Nothing changes
    /// while a button is down, so a drag isn't cut off.
    func trackMouse() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let mouse = NSEvent.mouseLocation
        var found = false
        for pane in order {
            guard let pet = pets[pane], let panel = panels[pane] else { continue }
            let over = !found && !PetPanel.allHidden && !pet.isGone && !pet.arriving
                && pet.screenHitBox?.contains(mouse) == true
            found = found || over
            panel.mouseOver = over
            pet.hovering = over
        }
    }

    // MARK: Menu bar

    /// A Poké Ball in the menu bar, for every pet at once: Hide Pets / Show
    /// Pets, Return Idle Pets and Let Out All Pets.
    func setUpMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = menuBarBall()
        item.button?.toolTip = "Claude Pet"
        item.button?.appearsDisabled = PetPanel.allHidden
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Not busy and not waiting on you, as Return to Poké Ball allows.
    func isIdle(_ pet: PetView) -> Bool {
        !pet.isGone && pet.transition == nil && pet.mood != .working && pet.mood != .alert
    }

    /// Rebuilt each time it opens, so its counts are current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let live = order.compactMap { pets[$0] }
        let idle = live.filter(isIdle).count, resting = live.filter(\.isGone).count

        func add(_ title: String, _ action: Selector, enabled: Bool = true) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
        }
        add(PetPanel.allHidden ? "Show Pets" : "Hide Pets", #selector(toggleHidden))
        menu.addItem(.separator())
        add(idle == 0 ? "Return Idle Pets" : "Return Idle Pets (\(idle))", #selector(returnIdle),
            enabled: idle > 0 && !PetPanel.allHidden)
        add(resting == 0 ? "Let Out All Pets" : "Let Out All Pets (\(resting))", #selector(letOutAll),
            enabled: resting > 0 && !PetPanel.allHidden)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Pet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func toggleHidden() {
        PetPanel.allHidden.toggle()
        statusItem?.button?.appearsDisabled = PetPanel.allHidden
        panels.values.forEach { $0.refreshShown() }
        trackMouse()
    }

    /// Every pet that isn't busy or waiting on you goes into its ball.
    @objc func returnIdle() {
        pets.values.filter(isIdle).forEach { $0.returnToBall() }
    }

    /// Every pet that's away comes back out, their balls thrown in together.
    @objc func letOutAll() {
        for pane in order where pets[pane]?.isGone == true { pets[pane]?.wake() }
    }

    /// Slides a panel that's already on screen; puts a new one straight in place.
    func move(_ panel: PetPanel, to point: NSPoint, animated: Bool = true) {
        guard panel.frame.origin != point else { return }
        let frame = NSRect(origin: point, size: panel.frame.size)
        if animated && placed.contains(ObjectIdentifier(panel)) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
            placed.insert(ObjectIdentifier(panel))
        }
    }
}

/// A small Claude Code terminal window for the mock screenshot, mid-task.
func drawMockTerminal(centeredIn canvas: NSSize) {
    let font = NSFont(name: "Menlo", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
    let text = NSColor(white: 0.9, alpha: 1), dim = NSColor(white: 0.55, alpha: 1)
    let orange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    let green = NSColor(srgbRed: 0.31, green: 0.73, blue: 0.40, alpha: 1)
    let amber = NSColor(srgbRed: 0.85, green: 0.64, blue: 0.25, alpha: 1)
    let border = NSColor(white: 0.42, alpha: 1)

    typealias Line = [(String, NSColor)]
    /// A row inside a box, indented past its border.
    func row(_ inner: Line) -> Line { [("  ", text)] + inner }
    // Boxes are stroked as rounded rects (box-drawing glyphs leave gaps at
    // this line height): (first line, last line, width in columns, colour).
    let boxes: [(Int, Int, Int, NSColor)] = [(0, 6, 52, orange), (20, 22, 76, border)]
    let lines: [Line] = [
        [],
        row([("✻", orange), (" Welcome to Claude Code!", text)]),
        [],
        row([("  /help for help, /status for your setup", dim)]),
        [],
        row([("  cwd: ~/projects/side-quest", dim)]),
        [],
        [],
        [("> add a dark mode toggle to the settings page", dim)],
        [],
        [("●", text), (" I'll add a toggle to the settings page and wire it to the theme.", text)],
        [],
        [("●", green), (" Read", text), ("(src/settings/SettingsPage.tsx)", dim)],
        [("  ⎿", dim), ("  Read 142 lines", dim)],
        [],
        [("●", green), (" Update", text), ("(src/settings/SettingsPage.tsx)", dim)],
        [("  ⎿", dim), ("  Updated src/settings/SettingsPage.tsx with 18 additions", dim)],
        [],
        [("✻", orange), (" Simmering…", orange), (" (14s · ↓ 1.2k tokens · esc to interrupt)", dim)],
        [],
        [],
        row([(">", text)]),
        [],
        [("  ⏵⏵ auto mode on", amber), (" (shift+tab to cycle)", dim)],
    ]

    let column = ("M" as NSString).size(withAttributes: [.font: font]).width
    let lineHeight: CGFloat = 17, titleBar: CGFloat = 28, padding: CGFloat = 14
    let size = NSSize(width: (78 * column + 2 * padding).rounded(),
                      height: titleBar + 2 * padding + CGFloat(lines.count) * lineHeight)
    let frame = NSRect(x: ((canvas.width - size.width) / 2).rounded(),
                       y: ((canvas.height - size.height) / 2 + 30).rounded(), // a touch above centre
                       width: size.width, height: size.height)

    // The window, with a soft shadow under it.
    let window = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowColor = NSColor(white: 0, alpha: 0.45)
    shadow.set()
    NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 0.97).setFill()
    window.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.12).setStroke()
    window.lineWidth = 1
    window.stroke()

    // Title bar: traffic lights and the title.
    let lights = [NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1),
                  NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1),
                  NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1)]
    for (i, color) in lights.enumerated() {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: frame.minX + 12 + CGFloat(i) * 20, y: frame.maxY - titleBar / 2 - 6,
                                    width: 12, height: 12)).fill()
    }
    let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                     .foregroundColor: dim]
    let title = "side-quest — claude" as NSString
    let titleSize = title.size(withAttributes: titleAttrs)
    title.draw(at: NSPoint(x: frame.midX - titleSize.width / 2, y: frame.maxY - titleBar / 2 - titleSize.height / 2),
               withAttributes: titleAttrs)

    // Each segment starts at its own column, so a wide fallback glyph can't shift what follows.
    let lineBottom = { (i: Int) in frame.maxY - titleBar - padding - CGFloat(i + 1) * lineHeight }
    for (i, line) in lines.enumerated() {
        var col = 0
        for (string, color) in line {
            (string as NSString).draw(at: NSPoint(x: frame.minX + padding + CGFloat(col) * column, y: lineBottom(i)),
                                      withAttributes: [.font: font, .foregroundColor: color])
            col += string.count
        }
    }

    // Box edges run through the middle of their first and last lines.
    for (first, last, width, color) in boxes {
        let box = NSRect(x: frame.minX + padding + column / 2,
                         y: lineBottom(last) + lineHeight / 2,
                         width: CGFloat(width - 1) * column,
                         height: lineBottom(first) - lineBottom(last))
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        path.lineWidth = 1
        color.setStroke()
        path.stroke()
    }
}

/// The four agents in the mock screenshot, top to bottom. The picker render
/// shows the same party, as if you'd right-clicked Gengar.
let demoParty = ["charmander", "snorlax", "gengar", "ditto"]

/// A generation's Pokémon picker on white for visual regression checks.
@MainActor
func renderPicker(to path: String, generation: Int = 1) {
    let index = min(max(generation, 1), PokemonCatalog.generations.count) - 1
    let names = PokemonCatalog.names(in: PokemonCatalog.generations[index].range)
    let current = generation == 1 ? "gengar" : names.first ?? "gengar"
    let grid = PokemonGrid(names: names, current: current,
                           taken: generation == 1 ? Set(demoParty).subtracting(["gengar"]) : []) { _ in }
    grid.hovered = grid.names.firstIndex(of: generation == 1 ? "pikachu" : current)
    guard let rep = grid.bitmapImageRepForCachingDisplay(in: grid.bounds),
          let canvas = NSBitmapImageRep(
              bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
    // In light mode whatever the Mac is set to, so the names are dark on the white.
    let light = NSAppearance(named: .aqua)!
    grid.appearance = light
    light.performAsCurrentDrawingAppearance { grid.cacheDisplay(in: grid.bounds, to: rep) }
    let rect = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.white.setFill()
    rect.fill()
    // Over the white, not in place of it (a plain draw copies the clear pixels across).
    rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    try? canvas.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// A mock screenshot: four pets in different moods stacked on a wallpaper
/// image, laid out exactly as on screen, at one pixel per point.
@MainActor
func renderDesktop(background path: String, to out: String, arrangement: Arrangement = Arrangement()) {
    guard let wallpaper = NSImage(contentsOfFile: path), let rep = wallpaper.representations.first else { return }
    let size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    let poses: [(mood: Mood, tick: Int, walkX: CGFloat)] = [
        (.working, 4, 6),   // Charmander walking right over its dots
        (.done, 3, 0),      // Snorlax at the top of its jump, over "Snorlax is done"
        (.alert, 3, 0),     // Gengar mid-hop between red flashes, so it reads as Gengar
        (.sleeping, 8, 0),  // Ditto with z's drifting up
    ]
    let cast = zip(demoParty, poses).map { (pokemon: $0, mood: $1.mood, tick: $1.tick, walkX: $1.walkX) }
    let pets = cast.enumerated().compactMap { i, c -> PetView? in
        guard let sheet = SpriteSheet.named(c.pokemon) else { return nil }
        let pet = PetView(agent: Agent(pane: "demo:\(i)", status: "idle", title: "", project: "demo"),
                          pokemon: c.pokemon, sheet: sheet)
        pet.mood = c.mood
        pet.tick = c.tick
        pet.walkX = c.walkX
        return pet
    }
    for (i, pet) in pets.enumerated() { pet.captionAbove = !arrangement.vertical && i % 2 == 1 }
    let origins = stackOrigins(pets, in: NSRect(origin: .zero, size: size), arrangement: arrangement)

    guard let canvas = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: canvas) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    wallpaper.draw(in: NSRect(origin: .zero, size: size))
    drawMockTerminal(centeredIn: size)
    // Pets render at the screen's 2x; sampled straight down to 1x, a 3-point
    // sprite pixel is exactly 3 pixels, so they stay crisp.
    context.imageInterpolation = .none
    for (pet, origin) in zip(pets, origins).reversed() { // bottom first, so upper pets draw on top
        guard let petRep = pet.bitmapImageRepForCachingDisplay(in: pet.bounds) else { continue }
        pet.cacheDisplay(in: pet.bounds, to: petRep)
        petRep.draw(in: NSRect(origin: origin, size: pet.bounds.size), from: .zero, operation: .sourceOver,
                    fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.none.rawValue])
    }
    NSGraphicsContext.restoreGraphicsState()
    try? canvas.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
}

/// Renders every mood (top row), the whole roster, and a Poké Ball thrown in
/// from the right edge (bottom strip, every few frames) into a PNG.
@MainActor
func renderSheet(to path: String) {
    guard let sample = SpriteSheet.named("pikachu") else { return }
    // (mood, tick, walkX, hovering, Poké Ball animation and how far through, context used)
    let moods: [(Mood, Int, CGFloat, Bool, (Transition.Kind, Int)?, Double?)] = [
        (.idle, 0, 0, false, nil, nil), (.idle, 2, 0, true, nil, nil), (.working, 2, 12, false, nil, nil),
        (.working, 4, -12, false, nil, nil), (.alert, 4, 0, false, nil, nil), (.alert, 3, 0, false, nil, nil),
        (.done, 3, 0, false, nil, nil), (.sleeping, 0, 0, false, nil, nil),
        (.stored, 10, 0, false, (.recall, 1), nil), (.stored, 10, 0, false, (.recall, 4), nil),
        (.stored, 10, 0, false, (.recall, 6), nil), (.idle, 10, 0, false, (.release, 1), nil),
        (.idle, 10, 0, false, (.release, 3), nil),
        (.idle, 0, 0, true, nil, 0.3), (.working, 2, 12, true, nil, 0.65), (.idle, 0, 0, false, nil, 0.93),
    ]
    let cell = NSSize(width: PetView.width, height: PetView.height(for: sample))
    let rows = (roster.count + 7) / 8
    let strip = NSSize(width: 900, height: 260)
    let size = NSSize(width: cell.width * CGFloat(moods.count), height: cell.height + CGFloat(rows) * 110 + strip.height)
    guard let sheet = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: sheet) else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor(white: 0.9, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()

    for (i, (mood, tick, walkX, hover, transition, context)) in moods.enumerated() {
        let agent = Agent(pane: "w1:p1", status: "idle", title: "", project: "side-quest")
        let view = PetView(agent: agent, pokemon: "pikachu", sheet: sample)
        view.mood = mood
        view.tick = tick
        view.walkX = walkX
        view.walkDirection = walkX < 0 ? -1 : 1
        view.hovering = hover
        view.transition = transition.map { Transition(kind: $0.0, start: tick - $0.1) }
        view.contextLeft = context
        view.captionAbove = hover && context != nil
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
        view.cacheDisplay(in: view.bounds, to: rep)
        rep.draw(in: NSRect(x: CGFloat(i) * cell.width, y: size.height - cell.height,
                            width: cell.width, height: cell.height))
    }

    context.cgContext.interpolationQuality = .none
    for (i, name) in roster.enumerated() {
        guard let frame = SpriteSheet.named(name)?.frames.first else { continue }
        let x = CGFloat(i % 8) * cell.width + (cell.width - 96) / 2
        let y = size.height - cell.height - CGFloat(i / 8 + 1) * 110
        context.cgContext.draw(frame, in: CGRect(x: x, y: y, width: 96, height: 96))
    }
    if let pokeball {
        // The strip stands in for the screen, its own right edge the screen's.
        let screen = NSRect(origin: .zero, size: strip)
        NSColor(white: 0.8, alpha: 1).setFill()
        screen.fill()
        let ball = CGFloat(pokeball.width) * PetView.scale
        let landing = NSRect(x: 640, y: 30, width: ball, height: ball)
        let flight = BallThrow(onto: landing, screen: screen, visible: screen)
        context.cgContext.translateBy(x: 0, y: strip.height) // drawBall expects a flipped view
        context.cgContext.scaleBy(x: 1, y: -1)
        for t in stride(from: CGFloat(0), through: 1, by: 0.06) {
            let (origin, turns) = flight.position(at: t)
            drawBall(pokeball, in: NSRect(x: origin.x, y: strip.height - origin.y - ball, width: ball, height: ball),
                     quarterTurns: turns)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? sheet.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}

/// herdr's agents in its sidebar order, then Claude sessions outside herdr, oldest first.
func currentAgents() -> [Agent] {
    let herdr = Herdr.agents()
    let records = HookSessions.liveRecords()
    let conductor = Conductor.agents(records: records)
    let conductorThreads = Set(Conductor.chats()?.compactMap {
        $0.agentType.lowercased().contains("codex") && !$0.claudeSession.isEmpty ? $0.claudeSession : nil
    } ?? [])
    let codex = CodexSessions.agents(excluding: conductorThreads)
    // Conductor's Claude chats run the hooks too, but its own list covers them.
    let hooked = conductor == nil ? records : records.filter { $0.app != Conductor.bundleID }
    var agents = (herdr ?? []) + HookSessions.agents(from: hooked, herdrRunning: herdr != nil) + ClaudeApp.agents()
    for i in agents.indices where !agents[i].pane.hasPrefix(ClaudeApp.prefix) {
        agents[i].contextLeft = Context.remaining(by: agents[i], records: records)
    }
    return agents + (conductor ?? []) + codex
}

// MARK: - Context

/// How much of each agent's context window remains, derived from the token
/// counts Claude Code writes to the session transcript.
enum Context {
    /// Token counts by transcript, re-read only when the file changes.
    private static var cache: [String: (modified: Date, tokens: Int?)] = [:]

    static func remaining(by agent: Agent, records: [HookSessions.Record]) -> Double? {
        // A herdr pane's session is whichever reported from that pane most recently.
        let record = agent.pane.hasPrefix(HookSessions.prefix)
            ? records.first { HookSessions.prefix + $0.session == agent.pane }
            : records.filter { $0.herdrPane == agent.pane }.max { $0.updated < $1.updated }
        // A herdr pane that hasn't run a hook since the pets were installed is
        // found through its process instead.
        let path = record?.transcript ?? (agent.pane.hasPrefix(HookSessions.prefix) ? nil : paneTranscript(agent.pane))
        return remaining(transcript: path, model: record?.model)
    }

    /// How much of a transcript's context window remains.
    static func remaining(transcript path: String?, model: String?) -> Double? {
        guard let path, let tokens = tokens(in: path) else { return nil }
        let used = Double(tokens) / Double(window(model: model, tokens: tokens))
        return max(0, min(1, 1 - used))
    }

    /// Panes' transcripts found by process, re-checked every half minute.
    private static var paneTranscripts: [String: (checked: Date, path: String?)] = [:]

    /// The transcript of the Claude Code session in a herdr pane. herdr names
    /// the pane's foreground process, and Claude Code keeps a file per process
    /// in ~/.claude/sessions naming its session, or the background job it was
    /// parked in.
    static func paneTranscript(_ pane: String) -> String? {
        if let cached = paneTranscripts[pane], Date().timeIntervalSince(cached.checked) < 30 { return cached.path }
        var path: String?
        if let data = Herdr.run(["pane", "process-info", "--pane", pane]),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let info = (json["result"] as? [String: Any])?["process_info"] as? [String: Any],
           let processes = info["foreground_processes"] as? [[String: Any]] {
            path = processes.lazy.compactMap { ($0["pid"] as? Int).flatMap(session(ofPid:)) }.compactMap(transcript(of:)).first
        }
        paneTranscripts[pane] = (Date(), path)
        return path
    }

    static let sessionsDirectory = NSHomeDirectory() + "/.claude/sessions"

    static func sessionFile(_ name: String) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: sessionsDirectory + "/" + name) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The session a Claude Code process is showing.
    static func session(ofPid pid: Int) -> String? {
        guard let file = sessionFile("\(pid).json") else { return nil }
        guard let job = file["parkedJobId"] as? String else { return file["sessionId"] as? String }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDirectory)) ?? []
        return names.lazy.filter { $0.hasSuffix(".json") }.compactMap(sessionFile).first {
            $0["jobId"] as? String == job && ($0["pid"] as? Int).map { isAlive(pid_t($0)) } == true
        }?["sessionId"] as? String
    }

    static func transcript(of session: String) -> String? {
        let projects = NSHomeDirectory() + "/.claude/projects"
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        return folders.lazy.map { "\(projects)/\($0)/\(session).jsonl" }.first { FileManager.default.fileExists(atPath: $0) }
    }

    static func tokens(in path: String) -> Int? {
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        else { return nil }
        if let cached = cache[path], cached.modified == modified { return cached.tokens }
        let tokens = latestTokens(in: path)
        cache[path] = (modified, tokens)
        return tokens
    }

    /// The input tokens of the main conversation's latest reply. nil before the
    /// first reply, and after a compaction until the next one.
    static func latestTokens(in path: String) -> Int? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 524_288 ? size - 524_288 : 0)
        let tail = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        for line in tail.split(separator: "\n").reversed() {
            if line.contains("\"subtype\":\"compact_boundary\"") { return nil }
            guard line.contains("\"type\":\"assistant\""), line.contains("\"usage\""),
                  !line.contains("\"isSidechain\":true"),
                  let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let usage = (json["message"] as? [String: Any])?["usage"] as? [String: Any] else { continue }
            let tokens = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
                .reduce(0) { $0 + ((usage[$1] as? Int) ?? 0) }
            if tokens > 0 { return tokens } // skip error placeholders with empty usage
        }
        return nil
    }

    /// 1M for extended-context sessions, otherwise 200k. Transcripts don't say
    /// which, so: past 200k it must be 1M; below that, the session's model if
    /// SessionStart reported it, else the default model in Claude Code's settings.
    static func window(model: String?, tokens: Int) -> Int {
        if tokens > 200_000 { return 1_000_000 }
        return (model ?? defaultModel() ?? "").contains("[1m]") ? 1_000_000 : 200_000
    }

    static func defaultModel() -> String? {
        guard let data = FileManager.default.contents(atPath: NSHomeDirectory() + "/.claude/settings.json"),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return settings["model"] as? String
    }
}

#if !TESTING
@main
struct ClaudePet {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.contains("--hook") {
            HookSessions.handleHook()
            return
        }
        if args.contains("--status") {
            for agent in currentAgents() {
                let context = agent.contextLeft.map { "ctx \(Int(($0 * 100).rounded()))% left" } ?? "ctx ?"
                print(agent.pane, agent.status, agent.kind.rawValue, agent.label, context, agent.app ?? "")
            }
            return
        }
        if args.contains("--validate-sprites") {
            let missing = roster.flatMap { name in
                [false, true].compactMap { shiny in
                    SpriteSheet.named(name, shiny: shiny) == nil ? name + (shiny ? " (shiny)" : " (normal)") : nil
                }
            }
            if missing.isEmpty {
                print("Validated \(roster.count * 2) normal and shiny Pokémon sprite sheets.")
            } else {
                print("Missing or invalid sprites:", missing.joined(separator: ", "))
                exit(1)
            }
            return
        }
        if args.contains(where: { $0.hasPrefix("--render") }) {
            PetView.recordsActivity = false
            PetView.scale = PetSize.medium // the docs show the default size
            if let i = args.firstIndex(of: "--scale"), i + 1 < args.count, let value = Double(args[i + 1]) {
                PetView.scale = CGFloat(value)
            }
        }
        if let i = args.firstIndex(of: "--render"), i + 1 < args.count {
            renderSheet(to: args[i + 1])
            return
        }
        if let i = args.firstIndex(of: "--render-desktop"), i + 2 < args.count {
            // Optional: "horizontal" and/or a corner such as "topLeft".
            var arrangement = Arrangement()
            arrangement.vertical = !args.contains("horizontal")
            if let corner = args.compactMap(Arrangement.Corner.init(rawValue:)).first { arrangement.corner = corner }
            renderDesktop(background: args[i + 1], to: args[i + 2], arrangement: arrangement)
            return
        }
        if let i = args.firstIndex(of: "--render-picker"), i + 1 < args.count {
            let generation = i + 2 < args.count ? Int(args[i + 2]) ?? 1 : 1
            renderPicker(to: args[i + 1], generation: generation)
            return
        }
        // One Claude Pet at a time.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
#endif
