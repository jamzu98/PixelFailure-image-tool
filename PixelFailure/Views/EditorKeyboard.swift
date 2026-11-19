import AppKit
import SwiftUI

/// Routes key presses in one editor window to the bound commands, no matter
/// which panel has focus — except while text is being typed. Runs ahead of
/// the menu bar, so menu items only display (and fall back for) shortcuts.
@MainActor
final class EditorKeyboardRouter {
    weak var window: NSWindow?
    var focus: EditorFocus?

    private var monitor: Any?
    /// Tool to return to when Space is released.
    private var spaceReturnTool: EditorTool?
    /// Spring-loaded tool: the held key, when it went down, and the tool before.
    private var springKey: String?
    private var springStart: TimeInterval = 0
    private var springPrevious: EditorTool?
    /// Last tool used per key, so a shared key reopens the one you used last.
    private var lastToolForKey: [String: EditorTool] = [:]
    /// First digit of a quickly typed two-digit opacity.
    private var lastDigit: (value: Int, time: TimeInterval)?

    /// Hold this long before releasing a tool key to snap back.
    private static let springDelay: TimeInterval = 0.35

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: Routing

    private func handle(_ event: NSEvent) -> Bool {
        guard let window, let focus, event.window === window, window.isKeyWindow,
              window.attachedSheet == nil, !isTyping(in: window) else { return false }
        switch event.type {
        case .keyDown: return keyDown(event, focus)
        case .keyUp: return keyUp(event, focus)
        default: return false
        }
    }

    private func isTyping(in window: NSWindow) -> Bool {
        if let text = window.firstResponder as? NSTextView { return text.isEditable }
        return window.firstResponder is NSTextField
    }

    func keyDown(_ event: NSEvent, _ focus: EditorFocus) -> Bool {
        guard let combo = KeyCombo(event: event) else { return false }
        let state = focus.editorState
        let prefs = Preferences.shared

        // Space: temporary Hand while held.
        if combo == KeyCombo("space") {
            if !event.isARepeat, spaceReturnTool == nil, state.activeTool != .hand {
                spaceReturnTool = state.activeTool
                state.activeTool = .hand
            }
            return true
        }

        // 1…0: opacity of the brush, or of the selected layers.
        if !combo.hasModifiers, combo.key.count == 1, let digit = Int(combo.key) {
            if event.isARepeat { return true }
            return setOpacity(digit: digit, time: event.timestamp, focus)
        }

        let store = ShortcutStore.shared
        // The typed character first, then the physical key (see KeyCombo).
        var actions = KeyCombo.candidates(for: event).lazy
            .map { store.actions(for: $0) }.first { !$0.isEmpty } ?? []
        var cycles = !prefs.useShiftForToolSwitch
        if actions.isEmpty, combo.shift, prefs.useShiftForToolSwitch {
            // ⇧ + tool key cycles the tools sharing that key.
            actions = store.actions(for: combo.unshifted).filter { $0.tool != nil }
            cycles = true
        }
        guard !actions.isEmpty else { return false }

        let tools = actions.compactMap(\.tool)
        if tools.count == actions.count {
            if !event.isARepeat { switchTool(among: tools, cycles: cycles, key: combo, time: event.timestamp, state) }
            return true
        }

        guard let action = actions.first(where: { $0.tool == nil && !$0.isAppLevel }) else { return false }
        if event.isARepeat && !action.repeats { return true }
        // Unavailable: let the menu bar have it (it beeps for a disabled item).
        guard EditorActions.canPerform(action, focus) else { return false }
        EditorActions.perform(action, focus)
        return true
    }

    func keyUp(_ event: NSEvent, _ focus: EditorFocus) -> Bool {
        guard let combo = KeyCombo(event: event) else { return false }
        let state = focus.editorState
        if combo.key == "space", let tool = spaceReturnTool {
            spaceReturnTool = nil
            if state.activeTool == .hand { state.activeTool = tool }
            return true
        }
        if combo.key == springKey {
            springKey = nil
            if Preferences.shared.springLoadedTools,
               event.timestamp - springStart >= Self.springDelay,
               let previous = springPrevious {
                EditorActions.select(previous, state)
            }
            springPrevious = nil
            return true
        }
        return false
    }

    // MARK: Tools

    private func switchTool(among tools: [EditorTool], cycles: Bool, key: KeyCombo,
                            time: TimeInterval, _ state: EditorState) {
        let current = state.activeTool
        let groupKey = key.unshifted.displayString
        let target: EditorTool
        if let index = tools.firstIndex(of: current) {
            target = cycles ? tools[(index + 1) % tools.count] : current
        } else {
            target = lastToolForKey[groupKey].flatMap { tools.contains($0) ? $0 : nil } ?? tools[0]
        }
        lastToolForKey[groupKey] = target
        guard target != current else { return }
        springKey = key.key
        springStart = time
        springPrevious = current
        EditorActions.select(target, state)
    }

    // MARK: Opacity

    /// Photoshop-style: 5 → 50%, 0 → 100%, two digits typed quickly → exact.
    private func setOpacity(digit: Int, time: TimeInterval, _ focus: EditorFocus) -> Bool {
        var percent = digit == 0 ? 100 : digit * 10
        if let last = lastDigit, time - last.time < 0.6 {
            percent = last.value * 10 + digit
            lastDigit = nil
        } else {
            lastDigit = (digit, time)
        }
        let state = focus.editorState
        let value = Double(percent) / 100

        if state.activeTool.isPaintTool {
            state.brush.opacity = max(value, 0.05)
            return true
        }
        let model = focus.document.model
        let ids = state.selectedLayerIDs.filter { !model.isEffectivelyLocked($0) }
        guard !ids.isEmpty else { return false }
        focus.document.update(focus.undoManager, actionName: "Layer Opacity") { model in
            for id in ids { model.modifyLayer(id: id) { $0.opacity = value } }
        }
        return true
    }
}

/// Reports the hosting NSWindow of a SwiftUI view.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
