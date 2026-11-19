import AppKit
import SwiftUI
import Testing
@testable import PixelFailure

@Suite("Keyboard router", .serialized)
@MainActor
struct KeyboardRouterTests {
    private let document: PixelDocument
    private let state = EditorState()
    private let router = EditorKeyboardRouter()
    private let focus: EditorFocus

    init() {
        let document = PixelDocument(model: ProjectModel())
        self.document = document
        focus = EditorFocus(document: document, editorState: state,
                            renderStore: RenderStore(document: document), undoManager: nil)
    }

    private static let keyCodes: [String: UInt16] = [
        "b": 11, "w": 13, "o": 31, "[": 33, "]": 30, "5": 23, "0": 29, "space": 49,
        "d": 2, "x": 7, "j": 38, "tab": 48, "v": 9,
    ]

    private func event(_ key: String, _ type: NSEvent.EventType = .keyDown,
                       flags: NSEvent.ModifierFlags = [], time: TimeInterval = 0,
                       repeat isRepeat: Bool = false) -> NSEvent {
        let chars = key == "space" ? " " : key == "tab" ? "\t" : key
        return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: time,
                                windowNumber: 0, context: nil, characters: chars,
                                charactersIgnoringModifiers: chars, isARepeat: isRepeat,
                                keyCode: Self.keyCodes[key]!)!
    }

    @discardableResult
    private func press(_ key: String, flags: NSEvent.ModifierFlags = [], down: TimeInterval = 0,
                       up: TimeInterval = 0.05) -> Bool {
        let handled = router.keyDown(event(key, flags: flags, time: down), focus)
        _ = router.keyUp(event(key, .keyUp, flags: flags, time: up), focus)
        return handled
    }

    @Test func toolKeysAndCycling() {
        #expect(press("b"))
        #expect(state.activeTool == .brush)
        press("w")
        #expect(state.activeTool == .wand)
        press("w")
        #expect(state.activeTool == .wand, "plain key keeps the current tool of the group")
        press("w", flags: .shift)
        #expect(state.activeTool == .objectSelect)
        press("w", flags: .shift)
        #expect(state.activeTool == .wand)
        press("v")
        press("w")
        #expect(state.activeTool == .wand, "returns to the group's last used tool")
    }

    @Test func springLoadedAndSpaceHand() {
        state.activeTool = .move
        press("b", down: 0, up: 1.0)
        #expect(state.activeTool == .move, "held key springs back")
        press("b", down: 2, up: 2.05)
        #expect(state.activeTool == .brush, "tap stays")

        _ = router.keyDown(event("space"), focus)
        #expect(state.activeTool == .hand)
        _ = router.keyDown(event("space", repeat: true), focus)
        _ = router.keyUp(event("space", .keyUp), focus)
        #expect(state.activeTool == .brush)
    }

    @Test func brushKeys() {
        state.activeTool = .brush
        press("5", down: 10)
        #expect(state.brush.opacity == 0.5)
        press("0", down: 20)
        #expect(state.brush.opacity == 1)
        press("5", down: 30)
        press("5", down: 30.2)
        #expect(abs(state.brush.opacity - 0.55) < 0.0001)

        let fg = state.brush.color, bg = state.brush.secondaryColor
        press("x")
        #expect(state.brush.color == bg && state.brush.secondaryColor == fg)
        press("d")
        #expect(state.brush.color == Preferences.shared.defaultForeground)
    }

    /// Shortcuts match the typed character, so non-US layouts reach [ ] = .
    @Test func layoutIndependentSymbols() {
        // US: ⇧[ types "{".
        #expect(KeyCombo.resolve(base: "[", typed: "{", flags: .shift).first == KeyCombo("[", "⇧"))
        // Finnish: ⌥8 types "[", ⇧⌥8 types "{", ⇧0 types "=".
        #expect(KeyCombo.resolve(base: "8", typed: "[", flags: .option).first == KeyCombo("["))
        #expect(KeyCombo.resolve(base: "8", typed: "{", flags: [.option, .shift]).first == KeyCombo("[", "⇧"))
        #expect(KeyCombo.resolve(base: "0", typed: "=", flags: [.command, .shift]).first == KeyCombo("=", "⌘"))
        #expect(KeyCombo.resolve(base: "9", typed: "]", flags: [.command, .option]).first == KeyCombo("]", "⌘"))
        // Option-letters keep the physical key (⌥B types ∫).
        #expect(KeyCombo.resolve(base: "b", typed: "∫", flags: .option) == [KeyCombo("b", "⌥")])
    }

    @Test func layerAndViewCommands() {
        let id = document.addFillLayer(undoManager: nil)
        state.selectedLayerID = id
        state.activeTool = .move
        press("5", down: 40)
        #expect(document.model.layer(id: id)?.opacity == 0.5)

        #expect(press("j", flags: .command))
        #expect(document.model.layers.count == 2)

        press("tab")
        #expect(state.panelsHidden)

        state.selectedLayerIDs = []
        #expect(!press("j", flags: .command), "unavailable command falls through to the menu")
    }
}

@Suite("Settings snapshots", .serialized)
@MainActor
struct SettingsSnapshotTests {
    @Test func renderPanes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("settings-snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for pane in SettingsPane.allCases {
            UserDefaults.standard.set(pane.rawValue, forKey: "settings.pane")
            let host = NSHostingView(rootView: SettingsView())
            host.frame = CGRect(x: 0, y: 0, width: 840, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
            let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("\(pane.rawValue).png"))
            window.orderOut(nil)
        }
        UserDefaults.standard.set(SettingsPane.general.rawValue, forKey: "settings.pane")
        print("SNAPSHOTS: \(directory.path)")
    }
}
