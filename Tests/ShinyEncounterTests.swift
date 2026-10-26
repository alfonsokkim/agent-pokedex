import AppKit

@main
struct ShinyEncounterTests {
    @MainActor static func main() {
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
