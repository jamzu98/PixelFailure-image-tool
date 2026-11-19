import Foundation
import Testing
@testable import PixelFailure

@Suite("Keyboard shortcuts and preferences")
@MainActor
struct ShortcutTests {
    private func freshDefaults() -> UserDefaults {
        let name = "ShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func photoshopDefaults() {
        let store = ShortcutStore(defaults: freshDefaults())
        #expect(store.combo(for: .toolBrush) == KeyCombo("b"))
        #expect(store.combo(for: .duplicateLayer) == KeyCombo("j", "⌘"))
        #expect(store.combo(for: .bringToFront) == KeyCombo("]", "⇧⌘"))
        #expect(store.combo(for: .fitOnScreen)?.displayString == "⌘0")
        #expect(store.combo(for: .fillForeground)?.displayString == "⌥⌫")
        // Tools share keys and cycle; nothing else may collide by default.
        #expect(store.actions(for: KeyCombo("w")) == [.toolWand, .toolObjectSelect])
        for action in ShortcutAction.allCases {
            guard let combo = action.defaultCombo else { continue }
            #expect(store.conflicts(for: combo, excluding: action).isEmpty, "\(action) collides")
        }
    }

    @Test func rebindingStealsAndPersists() {
        let defaults = freshDefaults()
        let store = ShortcutStore(defaults: defaults)
        let removed = store.set(KeyCombo("g", "⌘"), for: .rasterize)
        #expect(removed == [.groupLayers])
        #expect(store.combo(for: .groupLayers) == nil)
        #expect(store.isCustomized(.rasterize))

        let reloaded = ShortcutStore(defaults: defaults)
        #expect(reloaded.combo(for: .rasterize) == KeyCombo("g", "⌘"))
        #expect(reloaded.combo(for: .groupLayers) == nil)

        reloaded.reset(.groupLayers)
        #expect(reloaded.combo(for: .groupLayers) == KeyCombo("g", "⌘"))
        #expect(reloaded.combo(for: .rasterize) == nil)

        reloaded.resetAll()
        #expect(!reloaded.hasCustomizations)
    }

    @Test func toolsMayShareWithoutConflict() {
        let store = ShortcutStore(defaults: freshDefaults())
        #expect(store.set(KeyCombo("b"), for: .toolSmudge).isEmpty)
        #expect(store.actions(for: KeyCombo("b")) == [.toolBrush, .toolSmudge])
        #expect(store.set(KeyCombo("b"), for: .swapColors) == [.toolBrush, .toolSmudge])
    }

    @Test func menuShortcutsOnlyForModifiedKeys() {
        let store = ShortcutStore(defaults: freshDefaults())
        #expect(store.menuShortcut(.toolMove) == nil)
        #expect(store.menuShortcut(.selectAll) != nil)
        #expect(KeyCombo("f5").isMenuEligible)
    }

    @Test func brushSizeSteps() {
        let brush = BrushSettings()
        brush.size = 120
        brush.stepSize(larger: true)
        #expect(brush.size == 150)
        brush.size = 8
        brush.stepSize(larger: false)
        #expect(brush.size == 7)
        brush.size = 4
        brush.stepSize(larger: false)
        #expect(brush.size == 4)
    }

    @Test func preferencesRoundTrip() {
        let defaults = freshDefaults()
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.nudgeDistance == 1 && prefs.shiftNudgeDistance == 10)
        prefs.nudgeDistance = 3
        prefs.brushCursor = .precise
        let reloaded = Preferences(defaults: defaults)
        #expect(reloaded.nudgeDistance == 3)
        #expect(reloaded.brushCursor == .precise)
        reloaded.resetTools()
        #expect(Preferences(defaults: defaults).nudgeDistance == 1)
    }
}
