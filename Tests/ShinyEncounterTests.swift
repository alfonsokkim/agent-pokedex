import AppKit

@main
struct ShinyEncounterTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        PetView.recordsActivity = false
        let suite = "claude-pet-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }

        let paletteURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).pal")
        defer { try? FileManager.default.removeItem(at: paletteURL) }
        for invalid in ["1 2 3 junk", "1 2 256", "1 2", "-1 2 3"] {
            try! "JASC-PAL\n0100\n1\n\(invalid)\n".write(to: paletteURL, atomically: true, encoding: .utf8)
            check(SpritePalette.colors(in: paletteURL.path) == nil, "Malformed palette must be rejected: \(invalid)")
        }
        try! "JASC-PAL\n0100\n1\n1 2 3\n".write(to: paletteURL, atomically: true, encoding: .utf8)
        check(SpritePalette.colors(in: paletteURL.path) == [1, 2, 3], "A valid palette must load")
        for invalid: [UInt8] in [[], [1, 2], [1, 2, 3, 4], Array(repeating: 0, count: 771)] {
            check(SpriteSheet.frames(in: "\(SpriteSheet.directory)/virizion.png", palette: invalid) == nil,
                  "Invalid palette sizes must fail without crashing")
        }

        let results = (0..<25).map { value in
            ShinyEncounters.resolve(pane: "odds-\(value)", pokemon: "virizion", defaults: defaults, roll: { value })
        }
        check(results.filter { $0 }.count == 1, "Exactly one of 25 equally likely rolls must be shiny")
        var rolls = 0
        let initial = ShinyEncounters.resolve(pane: "persistent", pokemon: "virizion", defaults: defaults) {
            rolls += 1
            return 0
        }
        check(initial, "A zero roll must produce a shiny")
        for _ in 0..<20 {
            check(ShinyEncounters.resolve(pane: "persistent", pokemon: "virizion", defaults: defaults) {
                rolls += 1
                return 1
            }, "A saved appearance must survive repeated reads")
        }
        check(rolls == 1, "Reading an existing appearance must not reroll it")
        check(ShinyEncounters.resolve(pane: "persistent", pokemon: "virizion", defaults: UserDefaults(suiteName: suite)!),
              "A newly opened defaults store must recover the same shiny")
        check(!ShinyEncounters.resolve(pane: "persistent", pokemon: "virizion", reroll: true,
                                      defaults: defaults, roll: { 1 }), "A release must permit a new roll")
        check(ShinyEncounters.resolve(pane: "persistent", pokemon: "pikachu", defaults: defaults, roll: { 0 }),
              "Saved appearances must be scoped to their species")
        ShinyEncounters.save(false, pane: "persistent", pokemon: "pikachu", defaults: defaults)
        check(!ShinyEncounters.resolve(pane: "persistent", pokemon: "pikachu", defaults: defaults, roll: { 0 }),
              "Choosing a species must preserve its normal appearance")

        func silhouette(_ image: CGImage) -> [UInt8] {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<image.width * image.height).map { pixels[$0 * 4 + 3] }
        }
        func pixels(_ image: CGImage) -> Data {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Data(bytes: context.data!, count: image.width * image.height * 4)
        }
        for name in ["charmander", "squirtle"] {
            for shiny in [false, true] {
                let variant = shiny ? "shiny" : "normal"
                let fronts = SpriteSheet.frames(in: "\(SpriteSheet.directory)/front/\(name)_\(variant).png", frameSize: 32)!
                check(fronts.count == 32, "The source contains eight directions of four walking poses: \(name), \(variant)")
                let palette = SpritePalette.colors(in: "\(SpriteSheet.directory)/palettes/\(name)_\(variant).pal")!
                let original = SpriteSheet.frames(in: "\(SpriteSheet.directory)/\(name).png", palette: palette)!
                let updated = SpriteSheet.named(name, shiny: shiny)!
                for i in original.indices {
                    if i < 2 {
                        check(pixels(original[i]) != pixels(updated.frames[i]), "Front pose must be replaced: \(name), \(variant), \(i)")
                        check(SpriteSheet.visibleBox(of: original[i]).maxY == updated.boxes[i].maxY,
                              "Front replacement must retain the ground alignment: \(name), \(variant), \(i)")
                        check(silhouette(fronts[i]).filter { $0 > 0 }.count == silhouette(updated.frames[i]).filter { $0 > 0 }.count,
                              "Front alignment must not clip the artwork: \(name), \(variant), \(i)")
                    } else {
                        check(pixels(original[i]) == pixels(updated.frames[i]), "Side and back poses must remain identical: \(name), \(variant), \(i)")
                    }
                }
            }
            check(pixels(SpriteSheet.named(name)!.frames[0]) != pixels(SpriteSheet.named(name, shiny: true)!.frames[0]),
                  "Replacement fronts must support shiny colours: \(name)")
        }
        check(SpriteSheet.armSwingIndex(step: 1, time: 0.25) == 17, "Arm motion advances through intermediate poses")
        check(SpriteSheet.armSwingIndex(step: 1, time: 0.75, reducedMotion: true) == 1, "Reduced motion keeps a resting arm")
        for phase in 0..<SpriteSheet.armSwingPhases {
            check(abs(SpriteSheet.armSwingAngle(phase: phase + 1) - SpriteSheet.armSwingAngle(phase: phase)) < 0.021,
                  "Adjacent poses change by less than 1.2 degrees, including the loop seam")
        }
        for shiny in [false, true] {
            let golurk = SpriteSheet.named("golurk", shiny: shiny)!
            let poses = golurk.sideWalkFrames!
            check(poses.count == 64 && poses.allSatisfy { $0.width == 128 && $0.height == 128 }, "Both leg poses have a full shoulder-swing cycle")
            let rendered = poses.map(pixels)
            func differs(_ a: Data, _ b: Data, x: Range<Int>, y: Range<Int>) -> Bool {
                y.contains { row in x.contains { column in
                    let offset = (row * 128 + column) * 4
                    return a[offset..<offset + 4] != b[offset..<offset + 4]
                } }
            }
            check(differs(rendered[16], rendered[48], x: 72..<96, y: 52..<76), "The upper arm rotates along with the hand")
            check(differs(rendered[16], rendered[48], x: 48..<100, y: 80..<120), "The patterned gauntlet follows the same shoulder rotation")
            for phase in 0..<SpriteSheet.armSwingPhases {
                for step in 0..<2 {
                    let current = rendered[phase * 2 + step], resting = rendered[step]
                    check(!differs(current, resting, x: 40..<64, y: 48..<72), "The chest stays fixed throughout the entire cycle")
                    check(!differs(current, resting, x: 0..<128, y: 0..<40), "The head stays fixed")
                    check(!differs(current, resting, x: 0..<128, y: 120..<128), "The feet stay fixed for each leg pose")
                    let pivot = (50 * 128 + 86) * 4
                    check(current[pivot..<pivot + 4] == resting[pivot..<pivot + 4], "The shoulder pivot remains attached")
                }
            }
            let pet = PetView(agent: Agent(pane: "golurk-arm-hitbox-test", status: "working", title: "", project: "test"),
                              pokemon: "golurk", sheet: golurk)
            pet.setMood(.working)
            for direction: CGFloat in [-1, 1] {
                pet.walkDirection = direction
                for image in poses {
                    let pixels = SpriteSheet.visibleBox(of: image)
                    let box = CGRect(x: pixels.minX / 4, y: pixels.minY / 4, width: pixels.width / 4, height: pixels.height / 4)
                    let left = direction > 0 ? 32 - box.maxX : box.minX
                    let visible = NSRect(x: pet.homeX + left * PetView.scale, y: PetView.spriteTop + box.minY * PetView.scale,
                                         width: box.width * PetView.scale, height: box.height * PetView.scale)
                    check(pet.hitBox.contains(visible), "The whole rotating arm remains clickable in both directions")
                }
            }
        }
        let moving = PetView(agent: Agent(pane: "golurk-repaint-test", status: "working", title: "", project: "test"),
                             pokemon: "golurk", sheet: SpriteSheet.named("golurk")!)
        moving.setMood(.working)
        let host = NSWindow(contentRect: moving.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        host.contentView = moving
        check(!moving.armAnimationRunning, "A hidden pet does not start the faster clock")
        host.orderFront(nil)
        moving.fitSize()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let tick = moving.tick
            RunLoop.current.run(until: Date().addingTimeInterval(0.09))
            check(moving.armAnimationRunning && moving.tick == tick, "The arm clock runs independently of slower walking ticks")
            moving.setMood(.idle)
            RunLoop.current.run(until: Date().addingTimeInterval(0.09))
            check(!moving.armAnimationRunning, "The faster clock stops when Golurk stops walking")
            moving.setMood(.working)
            moving.fitSize()
            host.orderOut(nil)
            moving.animate()
            check(!moving.armAnimationRunning, "Hiding the pet stops its faster clock")
        }
        host.contentView = nil
        host.close()
        var paletteChecks = 0
        for name in roster {
            guard let normal = SpriteSheet.named(name), let shiny = SpriteSheet.named(name, shiny: true) else {
                fatalError("Missing normal or shiny sheet: \(name)")
            }
            check(normal.frames.count == shiny.frames.count, "Frame counts must match: \(name)")
            check(normal.top == shiny.top && normal.halfWidth == shiny.halfWidth && normal.boxes == shiny.boxes,
                  "Shinies must retain identical placement and visible bounds: \(name)")
            for (left, right) in zip(normal.frames, shiny.frames) {
                check(left.width == right.width && left.height == right.height, "Frame dimensions must match: \(name)")
                check(silhouette(left) == silhouette(right), "A shiny colour matching the background must remain opaque: \(name)")
            }
            paletteChecks += 2
        }

        let normal = SpriteSheet.named("virizion")!.frames[0]
        let shiny = SpriteSheet.named("virizion", shiny: true)!.frames[0]
        func greenPixels(_ image: CGImage) -> Int {
            let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                    bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            return (0..<image.width * image.height).filter { i in
                pixels[i * 4 + 3] > 0 && Int(pixels[i * 4 + 1]) > Int(pixels[i * 4]) + 15
                    && Int(pixels[i * 4 + 1]) > Int(pixels[i * 4 + 2]) + 15
            }.count
        }
        check(greenPixels(normal) > 30 && greenPixels(normal) > greenPixels(shiny), "Normal Virizion must be green")

        if CommandLine.arguments.count > 1 {
            let preview = CGContext(data: nil, width: 768, height: 192, bitsPerComponent: 8,
                                    bytesPerRow: 768 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            preview.setFillColor(CGColor(gray: 0.95, alpha: 1))
            preview.fill(CGRect(x: 0, y: 0, width: 768, height: 192))
            preview.interpolationQuality = .none
            for (i, image) in [normal, shiny, SpriteSheet.named("charizard")!.frames[0],
                               SpriteSheet.named("charizard", shiny: true)!.frames[0]].enumerated() {
                preview.draw(image, in: CGRect(x: i * 192, y: 0, width: 192, height: 192))
            }
            let bitmap = NSBitmapImageRep(cgImage: preview.makeImage()!)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Passed shiny odds, persistence, species changes, Virizion colours, and \(paletteChecks) sprite checks.")
    }
}
