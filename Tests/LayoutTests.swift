import AppKit

@main
struct LayoutTests {
    @MainActor static func main() {
        PetView.recordsActivity = false
        let originalScale = PetView.scale
        defer { PetView.scale = originalScale }
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError(message) }
        }
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }
        let names = ["snorunt", "groudon", "kyogre", "regirock", "regice", "registeel"]
        func party() -> [PetView] {
            names.enumerated().map { i, name in
                let pet = PetView(agent: Agent(pane: "layout-test:\(i)", status: "idle", title: "", project: "test"),
                                  pokemon: name, sheet: SpriteSheet.named(name)!)
                pet.setMood(.idle)
                return pet
            }
        }
        let visible = NSRect(x: -1600, y: 80, width: 1440, height: 1800)
        var checks = 0
        for scale in [PetSize.small, PetSize.medium, PetSize.large] {
            PetView.scale = scale
            let pets = party()
            check(Set(pets.map(\.spriteSize)).count > 1, "Fixture must include different canvas sizes")
            for corner in Arrangement.Corner.allCases {
                let arrangement = Arrangement(corner: corner)
                let origins = stackOrigins(pets, in: visible, arrangement: arrangement)
                let centers = zip(pets, origins).map { pet, origin in origin.x + pet.homeX + pet.spriteSize / 2 }
                check(centers.allSatisfy { close($0, centers[0]) }, "Every canvas must share the column centre: \(corner), \(scale)")
                for (pet, center) in zip(pets, centers) {
                    check(center - pet.footprintWidth / 2 >= visible.minX + stackMargin - 0.001,
                          "Left edge must leave room for visible pixels and pacing")
                    check(center + pet.footprintWidth / 2 <= visible.maxX - stackMargin + 0.001,
                          "Right edge must leave room for visible pixels and pacing")
                }
                check(zip(origins, origins.dropFirst()).allSatisfy { $0.y > $1.y }, "Agent order must stay top to bottom")
                let shifted = origins.map { NSPoint(x: $0.x + 2500, y: $0.y - 2300) }
                let clamped = keepOnScreen(pets, shifted, in: visible)
                let clampedCenters = zip(pets, clamped).map { pet, origin in origin.x + pet.homeX + pet.spriteSize / 2 }
                check(clampedCenters.allSatisfy { close($0, clampedCenters[0]) }, "Screen clamping must preserve alignment")
                checks += 1
            }
            for corner in Arrangement.Corner.allCases {
                let origins = stackOrigins(pets, in: visible, arrangement: Arrangement(vertical: false, corner: corner))
                check(origins.allSatisfy { close($0.y, origins[0].y) }, "Horizontal line-ups must retain their common ground")
                check(zip(origins, origins.dropFirst()).allSatisfy { $0.x < $1.x }, "Horizontal order must remain unchanged")
                checks += 1
            }
        }
        if CommandLine.arguments.count > 1 {
            PetView.scale = PetSize.medium
            let pets = party()
            let size = NSSize(width: 480, height: 1200)
            let origins = stackOrigins(pets, in: NSRect(origin: .zero, size: size), arrangement: Arrangement(corner: .topRight))
            let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)!
            NSColor(white: 0.96, alpha: 1).setFill()
            NSRect(origin: .zero, size: size).fill()
            let center = origins[0].x + pets[0].bounds.width / 2
            NSColor.lightGray.setFill()
            NSRect(x: center, y: 0, width: 1, height: size.height).fill()
            for (pet, origin) in zip(pets, origins).reversed() {
                let rep = pet.bitmapImageRepForCachingDisplay(in: pet.bounds)!
                pet.cacheDisplay(in: pet.bounds, to: rep)
                rep.draw(in: NSRect(origin: origin, size: pet.bounds.size), from: .zero, operation: .sourceOver,
                         fraction: 1, respectFlipped: false, hints: [.interpolation: NSImageInterpolation.none.rawValue])
            }
            NSGraphicsContext.restoreGraphicsState()
            try! canvas.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Passed \(checks) mixed-canvas layout checks across all corners and sizes.")
    }
}
