import AppKit

@main
struct ShinyHoverTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        PetView.recordsActivity = false
        let originalScale = PetView.scale
        defer { PetView.scale = originalScale }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fatalError(message) }
        }
        let agent = Agent(pane: "shiny-hover-test", status: "idle", title: "", project: "test")
        let normal = SpriteSheet.named("gengar")!
        let shiny = SpriteSheet.named("gengar", shiny: true)!
        let pet = PetView(agent: agent, pokemon: "gengar", sheet: normal)
        pet.setMood(.idle)
        pet.tick = 0
        pet.hovering = true
        check(pet.shinyBurst.start == nil, "Normal Pokemon must not sparkle")
        pet.hovering = false
        pet.applyAppearance(sheet: shiny, shiny: true)
        pet.hovering = true
        check(pet.shinyBurst.start == 0, "A shiny hover must start a burst")
        for _ in 0..<3 { pet.animate() }
        pet.hovering = true
        check(pet.shinyBurst.start == 0, "Mouse tracking must not restart the burst on every event")
        pet.hovering = false
        check(pet.shinyBurst.progress(at: pet.tick) != nil, "Leaving must let existing stars dissipate")
        for _ in 0..<ShinyHoverBurst.duration { pet.animate() }
        check(pet.shinyBurst.progress(at: pet.tick) == nil, "The burst must finish completely")
        pet.hovering = true
        let restarted = pet.shinyBurst.start
        check(restarted == pet.tick, "A new hover must replay the burst")
        for _ in 0..<ShinyHoverBurst.duration { pet.animate() }
        pet.hovering = true
        check(pet.shinyBurst.start == restarted && pet.shinyBurst.progress(at: pet.tick) == nil,
              "Holding the pointer must not loop the effect")
        check(pet.isShiny, "Hovering must never reroll the shiny appearance")
        pet.setPokemon("gengar", sheet: normal)
        check(!pet.isShiny && pet.shinyBurst.start == nil, "Changing species clears old stars")
        pet.applyAppearance(sheet: shiny, shiny: true)
        pet.hovering = false
        pet.arriving = true
        pet.hovering = true
        check(pet.shinyBurst.start == nil, "An arriving pet cannot sparkle yet")
        pet.arriving = false
        pet.transition = Transition(kind: .release, start: pet.tick)
        pet.hovering = false
        pet.hovering = true
        check(pet.shinyBurst.start == nil, "Do not overlap the release animation")
        pet.transition = nil
        pet.hovering = false
        pet.hovering = true
        pet.setMood(.stored)
        check(pet.shinyBurst.start == nil, "Recall clears the hover burst")

        // Reproduce the small-to-large species swap inside a real, hidden window.
        let panelPet = PetView(agent: agent, pokemon: "gengar", sheet: normal)
        let panel = NSPanel(contentRect: panelPet.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = panelPet
        let smallHeight = panel.frame.height
        let origin = panel.frame.origin
        panelPet.setPokemon("kyogre", sheet: SpriteSheet.named("kyogre")!)
        check(panel.frame.height > smallHeight, "Kyogre's window must grow with its larger canvas")
        check(panel.contentView!.frame.size == panel.frame.size && panelPet.frame.size == panel.frame.size,
              "The view and window must match after choosing a larger species")
        check(panel.frame.origin == origin, "Resizing must keep the ground anchored")
        panelPet.setPokemon("gengar", sheet: normal)
        check(panel.frame.height == smallHeight, "Swapping back must shrink the window too")
        panel.close()

        var burst = ShinyHoverBurst()
        burst.begin(at: 0)
        check(burst.progress(at: -1) == nil && burst.progress(at: 10) == nil, "Only active ticks may render")
        for scale in [PetSize.small, 1.81546875, PetSize.medium, PetSize.large] {
            PetView.scale = scale
            for name in roster {
                let view = PetView(agent: agent, pokemon: name, sheet: SpriteSheet.named(name)!)
                for (walk, lift): (CGFloat, CGFloat) in [(0, 0), (-12, 0), (12, 0), (0, 18)] {
                    view.walkX = walk
                    for tick in 0..<ShinyHoverBurst.duration {
                        let stars = burst.stars(at: tick, around: view.hitBox.offsetBy(dx: 0, dy: -lift), in: view.bounds, scale: scale)
                        check(stars.count == 8, "Every burst has eight stars")
                        for star in stars {
                            check(star.alpha >= 0 && star.alpha <= 1, "Opacity must stay valid")
                            check(view.bounds.insetBy(dx: -0.001, dy: -0.001).contains(star.frame),
                                  "Stars must not be clipped: \(name), scale \(scale), tick \(tick)")
                        }
                    }
                }
            }
        }

        if CommandLine.arguments.count > 1 {
            PetView.scale = 3
            let view = PetView(agent: agent, pokemon: "gengar", sheet: shiny)
            view.applyAppearance(sheet: shiny, shiny: true)
            view.setMood(.idle)
            view.tick = 0
            view.hovering = true
            let cell = view.bounds.size
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell.width * 4), pixelsHigh: Int(cell.height),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)!
            NSColor(white: 0.12, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: cell.width * 4, height: cell.height).fill()
            for (index, tick) in [0, 3, 6, 9].enumerated() {
                view.tick = tick
                let frame = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: frame)
                frame.draw(in: NSRect(x: CGFloat(index) * cell.width, y: 0, width: cell.width, height: cell.height),
                    from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        }
        print("Passed \(checks) shiny hover, particle bounds, and live window-resizing checks.")
    }
}
