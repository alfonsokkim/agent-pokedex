import AppKit

@main
struct PickerSearchTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        PetView.recordsActivity = false
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
        }
        check(PokemonCatalog.matching("CHAR") == ["charmander", "charmeleon", "charizard", "chimchar"], "Case-insensitive substring search")
        check(PokemonCatalog.matching("  porygon  ") == ["porygon", "porygon2", "porygon_z"], "Whitespace and cross-generation matching")
        check(PokemonCatalog.matching("mr. mi") == ["mr_mime"], "Displayed names are searchable")
        check(PokemonCatalog.matching("mr-mime") == ["mr_mime"], "Catalog names are searchable")
        check(PokemonCatalog.matching("mr_mime") == ["mr_mime"], "Asset names are searchable")
        check(PokemonCatalog.matching("zzzzzz").isEmpty, "No false results for an unmatched query")
        let allPanel = PokemonPickerWindow(current: "gengar", taken: []) { _ in }
        check(allPanel.picker.generations.selectedSegment == 0 && allPanel.picker.grid.names.count == 649,
              "The default picker opens All with generation tabs available")
        allPanel.close()
        let panel = PokemonPickerWindow(current: "gengar", taken: ["pikachu"], generation: 1) { _ in }
        let picker = panel.picker
        check(panel.canBecomeKey && panel.initialFirstResponder === picker.searchField, "The native picker can accept keyboard focus")
        check(picker.grid.names.count == 151, "A generation choice initially shows its region")
        check(picker.grid.current == "gengar" && picker.grid.taken == ["pikachu"], "Search preserves current and in-use markers")
        picker.grid.setHovered(picker.grid.names.firstIndex(of: "pikachu"))
        check(picker.grid.toolTip?.contains("swaps") == true, "An in-use preview explains the swap")
        func search(_ text: String) {
            picker.searchField.stringValue = text
            picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.searchField))
        }
        picker.grid.hovered = 4
        search("ZOR")
        check(picker.grid.names == ["scizor", "bronzor", "zorua", "zoroark"], "Typing immediately searches all five generations from a regional picker")
        check(picker.generations.selectedSegment == 0, "Search identifies its global scope")
        check(picker.grid.hovered == nil, "Filtering clears a stale hover index")
        check(picker.grid.toolTip == nil, "Filtering clears a stale in-use tooltip")
        check(picker.scroll.contentView.bounds.origin == .zero, "New results start at the top")
        search("zzzzzz")
        check(picker.grid.names.isEmpty && picker.resultCount.stringValue.hasPrefix("0 Pokémon"), "An unmatched search leaves no stale cells")
        search("")
        check(picker.grid.names.count == 151 && picker.generations.selectedSegment == 1, "Clearing restores the selected generation")
        search("porygon")
        picker.generations.selectedSegment = 5
        _ = picker.generations.sendAction(picker.generations.action, to: picker.generations.target)
        check(picker.searchField.stringValue.isEmpty && picker.grid.names.count == 156, "Choosing a region clears the global query")
        search("char")
        var picked: String?
        picker.onPick = { picked = $0 }
        picker.grid.onPick(picker.grid.names[1])
        check(picked == "charmeleon", "A filtered cell picks the matching species")
        if let bitmap = picker.bitmapImageRepForCachingDisplay(in: picker.bounds) {
            picker.appearance = NSAppearance(named: .aqua)
            picker.cacheDisplay(in: picker.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pokemon-search-preview.png"))
        }
        panel.close()
        func preview(taken: Set<String>) -> NSBitmapImageRep {
            let grid = PokemonGrid(names: ["regirock", "regice", "registeel", "groudon", "kyogre", "charmander", "squirtle"],
                                   current: "", taken: taken, onPick: { _ in })
            let host = NSWindow(contentRect: grid.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.appearance = NSAppearance(named: .aqua)
            host.contentView = grid
            let image = grid.bitmapImageRepForCachingDisplay(in: grid.bounds)!
            grid.cacheDisplay(in: grid.bounds, to: image)
            host.close()
            return image
        }
        let available = preview(taken: [])
        let assigned = preview(taken: ["regirock"])
        let scale = assigned.pixelsWide / Int(available.size.width)
        var visiblePixels = 0
        var fadedPixels = 0
        for x in 16 * scale..<58 * scale {
            for y in 16 * scale..<60 * scale {
                let original = available.colorAt(x: x, y: y)!
                if original.alphaComponent > 0.5 {
                    visiblePixels += 1
                    if abs(assigned.colorAt(x: x, y: y)!.alphaComponent - original.alphaComponent * 0.4) < 0.02 {
                        fadedPixels += 1
                    }
                }
            }
        }
        check(visiblePixels > 0 && fadedPixels == visiblePixels, "Assigned sprites retain their in-use fade")
        try? assigned.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/pokemon-picker-preview.png"))
        print("Passed \(checks) Pokémon picker search checks.")
    }
}
