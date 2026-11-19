import AppKit
import SwiftUI

// MARK: - Key combination

/// One key plus modifiers. `key` is a lowercased printable character
/// ("v", "[", "1") or a special key name ("space", "delete", "f5").
nonisolated struct KeyCombo: Codable, Hashable, Sendable {
    var key: String
    var command = false
    var shift = false
    var option = false
    var control = false

    /// Builds a combo from a modifier string of ⌘ ⇧ ⌥ ⌃ glyphs.
    init(_ key: String, _ modifiers: String = "") {
        self.key = key
        command = modifiers.contains("⌘")
        shift = modifiers.contains("⇧")
        option = modifiers.contains("⌥")
        control = modifiers.contains("⌃")
    }

    var hasModifiers: Bool { command || shift || option || control }
    /// Menus only carry shortcuts that can't collide with typing.
    var isMenuEligible: Bool { command || control || key.hasPrefix("f") && key.count > 1 }

    var unshifted: KeyCombo {
        var copy = self
        copy.shift = false
        return copy
    }

    var displayString: String {
        var out = ""
        if control { out += "⌃" }
        if option { out += "⌥" }
        if shift { out += "⇧" }
        if command { out += "⌘" }
        return out + Self.keyGlyph(key)
    }

    static func keyGlyph(_ key: String) -> String {
        switch key {
        case "space": "Space"
        case "tab": "⇥"
        case "return": "↩"
        case "escape": "⎋"
        case "delete": "⌫"
        case "forwardDelete": "⌦"
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "home": "↖"
        case "end": "↘"
        case "pageUp": "⇞"
        case "pageDown": "⇟"
        default: key.uppercased()
        }
    }
}

extension KeyCombo {
    private static let specialKeyCodes: [UInt16: String] = [
        49: "space", 48: "tab", 36: "return", 76: "return", 53: "escape",
        51: "delete", 117: "forwardDelete", 123: "left", 124: "right", 125: "down", 126: "up",
        115: "home", 119: "end", 116: "pageUp", 121: "pageDown",
        122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6",
        98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12",
    ]

    /// The combo an AppKit key event represents, or nil for bare modifiers.
    init?(event: NSEvent) {
        guard let first = Self.candidates(for: event).first else { return nil }
        self = first
    }

    /// Ways to read one key event, best first. Shortcuts name characters,
    /// so on layouts where `[` is ⌥8 (Finnish, German, …) the typed
    /// character wins over the physical key; the physical reading follows.
    static func candidates(for event: NSEvent) -> [KeyCombo] {
        let flags = event.modifierFlags
        if let special = specialKeyCodes[event.keyCode] {
            return [KeyCombo(special, flags: flags)]
        }
        guard let base = event.characters(byApplyingModifiers: [])?.first, !base.isWhitespace else {
            return []
        }
        let typed = event.characters(byApplyingModifiers: flags.intersection([.shift, .option]))?.first
        var result = resolve(base: base, typed: typed, flags: flags)
        // ⌘+ zooms in like ⌘= (where + is its own key, or ⇧=).
        if let first = result.first, first.key == "+" {
            var alias = first
            alias.key = "="
            result.insert(alias, at: 1)
        }
        return result
    }

    /// Shifted US symbols map back to their key, so ⇧[ is written ⇧[ not {.
    private static let shiftedSymbols: [Character: Character] = ["{": "[", "}": "]"]
    private static let symbolKeys = Set("[]{}=+-/\\;',.`")

    static func resolve(base: Character, typed: Character?, flags: NSEvent.ModifierFlags) -> [KeyCombo] {
        let physical = KeyCombo(String(base).lowercased(), flags: flags)
        guard let typed, typed != base, symbolKeys.contains(typed) else { return [physical] }
        // The modifiers that produced the symbol are part of the character.
        var stripped = flags
        stripped.remove([.shift, .option])
        var combo = KeyCombo(String(shiftedSymbols[typed] ?? typed), flags: stripped)
        if shiftedSymbols[typed] != nil { combo.shift = true }
        return [combo, physical]
    }

    private init(_ key: String, flags: NSEvent.ModifierFlags) {
        self.init(key)
        command = flags.contains(.command)
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        control = flags.contains(.control)
    }

    /// SwiftUI form, for menu items.
    var keyboardShortcut: KeyboardShortcut? {
        guard let equivalent = keyEquivalent else { return nil }
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return KeyboardShortcut(equivalent, modifiers: modifiers)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch key {
        case "space": return .space
        case "tab": return .tab
        case "return": return .return
        case "escape": return .escape
        case "delete": return .delete
        case "forwardDelete": return .deleteForward
        case "left": return .leftArrow
        case "right": return .rightArrow
        case "up": return .upArrow
        case "down": return .downArrow
        case "home": return .home
        case "end": return .end
        case "pageUp": return .pageUp
        case "pageDown": return .pageDown
        default:
            if key.hasPrefix("f"), key.count > 1, let n = Int(key.dropFirst()), (1...12).contains(n),
               let scalar = UnicodeScalar(NSF1FunctionKey + n - 1) {
                return KeyEquivalent(Character(scalar))
            }
            guard let first = key.first, key.count == 1 else { return nil }
            return KeyEquivalent(first)
        }
    }
}

// MARK: - Actions

enum ShortcutCategory: String, CaseIterable, Identifiable {
    case tools = "Tools"
    case painting = "Painting"
    case file = "File"
    case edit = "Edit"
    case generate = "Generate"
    case select = "Select"
    case layer = "Layer"
    case view = "View"

    var id: String { rawValue }
}

/// Every rebindable command. Defaults follow Photoshop where the app has an
/// equivalent; ⌘R stays Reroll, so rulers take ⇧⌘R.
enum ShortcutAction: String, CaseIterable, Identifiable {
    // Tools
    case toolMove = "tool.move", toolMarquee = "tool.marquee", toolLasso = "tool.lasso"
    case toolWand = "tool.wand", toolObjectSelect = "tool.objectSelect", toolCrop = "tool.crop"
    case toolEyedropper = "tool.eyedropper", toolBrush = "tool.brush", toolEraser = "tool.eraser"
    case toolClone = "tool.clone", toolHeal = "tool.heal", toolSmudge = "tool.smudge"
    case toolDodge = "tool.dodge", toolBurn = "tool.burn", toolPen = "tool.pen", toolNode = "tool.node"
    case toolHand = "tool.hand", toolZoom = "tool.zoom"
    // Painting
    case brushSmaller = "paint.smaller", brushLarger = "paint.larger"
    case brushSofter = "paint.softer", brushHarder = "paint.harder"
    case defaultColors = "paint.defaultColors", swapColors = "paint.swapColors"
    // File
    case newDocument = "file.new", newBlankCanvas = "file.newBlank"
    case openImageAsCanvas = "file.openImage", showHome = "file.home", export = "file.export"
    // Edit
    case fillForeground = "edit.fillForeground", fillBackground = "edit.fillBackground"
    case freeTransform = "edit.freeTransform", deselectLayers = "edit.deselectLayers"
    // Generate
    case reroll = "generate.reroll", randomize = "generate.randomize"
    // Select
    case selectAll = "select.all", deselect = "select.deselect", reselect = "select.reselect"
    case invertSelection = "select.invert", selectAllLayers = "select.allLayers"
    case selectSubject = "select.subject"
    // Layer
    case newLayer = "layer.new", duplicateLayer = "layer.duplicate"
    case groupLayers = "layer.group", ungroup = "layer.ungroup", clippingMask = "layer.clip"
    case lockLayer = "layer.lock", toggleVisibility = "layer.visibility"
    case bringForward = "layer.forward", sendBackward = "layer.backward"
    case bringToFront = "layer.front", sendToBack = "layer.back"
    case selectLayerAbove = "layer.selectAbove", selectLayerBelow = "layer.selectBelow"
    case flipHorizontal = "layer.flipH", flipVertical = "layer.flipV"
    case rasterize = "layer.rasterize", deleteLayer = "layer.delete"
    // View
    case zoomIn = "view.zoomIn", zoomOut = "view.zoomOut"
    case fitOnScreen = "view.fit", actualPixels = "view.actual"
    case toggleRulers = "view.rulers", toggleGrid = "view.grid", toggleGuides = "view.guides"
    case toggleSnap = "view.snap", toggleSmartGuides = "view.smartGuides"
    case clearGuides = "view.clearGuides", toggleNavigator = "view.navigator"
    case togglePanels = "view.panels", resetViewRotation = "view.resetRotation"

    var id: String { rawValue }

    var tool: EditorTool? {
        guard rawValue.hasPrefix("tool.") else { return nil }
        return EditorTool(rawValue: String(rawValue.dropFirst(5)))
    }

    static func forTool(_ tool: EditorTool) -> ShortcutAction {
        ShortcutAction(rawValue: "tool.\(tool.rawValue)")!
    }

    /// Commands that live outside any document window (menus handle them).
    var isAppLevel: Bool {
        [.newDocument, .newBlankCanvas, .openImageAsCanvas, .showHome].contains(self)
    }

    /// Holding the key repeats the command.
    var repeats: Bool {
        [.brushSmaller, .brushLarger, .brushSofter, .brushHarder, .zoomIn, .zoomOut,
         .selectLayerAbove, .selectLayerBelow, .bringForward, .sendBackward].contains(self)
    }

    var category: ShortcutCategory {
        switch rawValue.split(separator: ".").first {
        case "tool": .tools
        case "paint": .painting
        case "file": .file
        case "edit": .edit
        case "generate": .generate
        case "select": .select
        case "layer": .layer
        default: .view
        }
    }

    var title: String {
        if let tool { return tool.displayName }
        switch self {
        case .brushSmaller: return "Decrease Brush Size"
        case .brushLarger: return "Increase Brush Size"
        case .brushSofter: return "Decrease Brush Hardness"
        case .brushHarder: return "Increase Brush Hardness"
        case .defaultColors: return "Default Colors"
        case .swapColors: return "Swap Colors"
        case .newDocument: return "New…"
        case .newBlankCanvas: return "New Blank Canvas"
        case .openImageAsCanvas: return "Open Image as Canvas…"
        case .showHome: return "Home"
        case .export: return "Export…"
        case .fillForeground: return "Fill with Foreground Color"
        case .fillBackground: return "Fill with Background Color"
        case .freeTransform: return "Free Transform"
        case .deselectLayers: return "Deselect Layers"
        case .reroll: return "Reroll Seed"
        case .randomize: return "Randomize"
        case .selectAll: return "Select All"
        case .deselect: return "Deselect"
        case .reselect: return "Reselect"
        case .invertSelection: return "Invert Selection"
        case .selectAllLayers: return "Select All Layers"
        case .selectSubject: return "Select Subject"
        case .newLayer: return "New Layer"
        case .duplicateLayer: return "Layer via Copy / Duplicate"
        case .groupLayers: return "Group Layers"
        case .ungroup: return "Ungroup"
        case .clippingMask: return "Create/Release Clipping Mask"
        case .lockLayer: return "Lock/Unlock Layer"
        case .toggleVisibility: return "Show/Hide Layer"
        case .bringForward: return "Bring Forward"
        case .sendBackward: return "Send Backward"
        case .bringToFront: return "Bring to Front"
        case .sendToBack: return "Send to Back"
        case .selectLayerAbove: return "Select Layer Above"
        case .selectLayerBelow: return "Select Layer Below"
        case .flipHorizontal: return "Flip Horizontal"
        case .flipVertical: return "Flip Vertical"
        case .rasterize: return "Rasterize Layer"
        case .deleteLayer: return "Delete Layer"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .fitOnScreen: return "Fit on Screen"
        case .actualPixels: return "Actual Pixels (100%)"
        case .toggleRulers: return "Rulers"
        case .toggleGrid: return "Grid"
        case .toggleGuides: return "Guides"
        case .toggleSnap: return "Snap to Grid"
        case .toggleSmartGuides: return "Smart Guides"
        case .clearGuides: return "Clear Guides"
        case .toggleNavigator: return "Navigator"
        case .togglePanels: return "Show/Hide Panels"
        case .resetViewRotation: return "Reset View Rotation"
        default: return rawValue
        }
    }

    var defaultCombo: KeyCombo? {
        switch self {
        case .toolMove: KeyCombo("v")
        case .toolMarquee: KeyCombo("m")
        case .toolLasso: KeyCombo("l")
        case .toolWand, .toolObjectSelect: KeyCombo("w")
        case .toolCrop: KeyCombo("c")
        case .toolEyedropper: KeyCombo("i")
        case .toolBrush: KeyCombo("b")
        case .toolEraser: KeyCombo("e")
        case .toolClone: KeyCombo("s")
        case .toolHeal: KeyCombo("j")
        case .toolSmudge: KeyCombo("r")
        case .toolDodge, .toolBurn: KeyCombo("o")
        case .toolPen: KeyCombo("p")
        case .toolNode: KeyCombo("a")
        case .toolHand: KeyCombo("h")
        case .toolZoom: KeyCombo("z")

        case .brushSmaller: KeyCombo("[")
        case .brushLarger: KeyCombo("]")
        case .brushSofter: KeyCombo("[", "⇧")
        case .brushHarder: KeyCombo("]", "⇧")
        case .defaultColors: KeyCombo("d")
        case .swapColors: KeyCombo("x")

        case .newDocument: KeyCombo("n", "⌘")
        case .newBlankCanvas: KeyCombo("n", "⌥⌘")
        case .openImageAsCanvas: KeyCombo("o", "⌥⇧⌘")
        case .showHome: nil
        case .export: KeyCombo("e", "⌘")

        case .fillForeground: KeyCombo("delete", "⌥")
        case .fillBackground: KeyCombo("delete", "⌘")
        case .freeTransform: KeyCombo("t", "⌘")
        case .deselectLayers: KeyCombo("a", "⇧⌘")

        case .reroll: KeyCombo("r", "⌘")
        case .randomize: KeyCombo("r", "⌥⌘")

        case .selectAll: KeyCombo("a", "⌘")
        case .deselect: KeyCombo("d", "⌘")
        case .reselect: KeyCombo("d", "⇧⌘")
        case .invertSelection: KeyCombo("i", "⇧⌘")
        case .selectAllLayers: KeyCombo("a", "⌥⌘")
        case .selectSubject: nil

        case .newLayer: KeyCombo("n", "⇧⌘")
        case .duplicateLayer: KeyCombo("j", "⌘")
        case .groupLayers: KeyCombo("g", "⌘")
        case .ungroup: KeyCombo("g", "⇧⌘")
        case .clippingMask: KeyCombo("g", "⌥⌘")
        case .lockLayer: KeyCombo("/", "⌘")
        case .toggleVisibility: nil
        case .bringForward: KeyCombo("]", "⌘")
        case .sendBackward: KeyCombo("[", "⌘")
        case .bringToFront: KeyCombo("]", "⇧⌘")
        case .sendToBack: KeyCombo("[", "⇧⌘")
        case .selectLayerAbove: KeyCombo("]", "⌥")
        case .selectLayerBelow: KeyCombo("[", "⌥")
        case .flipHorizontal: KeyCombo("h", "⇧⌘")
        case .flipVertical: nil
        case .rasterize: nil
        case .deleteLayer: nil

        case .zoomIn: KeyCombo("=", "⌘")
        case .zoomOut: KeyCombo("-", "⌘")
        case .fitOnScreen: KeyCombo("0", "⌘")
        case .actualPixels: KeyCombo("1", "⌘")
        case .toggleRulers: KeyCombo("r", "⇧⌘")
        case .toggleGrid: KeyCombo("'", "⌘")
        case .toggleGuides: KeyCombo(";", "⌘")
        case .toggleSnap: KeyCombo(";", "⇧⌘")
        case .toggleSmartGuides: nil
        case .clearGuides: nil
        case .toggleNavigator: nil
        case .togglePanels: KeyCombo("tab")
        case .resetViewRotation: nil
        }
    }
}

/// Keys handled directly by the canvas, shown read-only in Settings.
struct FixedShortcut: Identifiable {
    let keys: String
    let title: String
    var id: String { title }

    static let all: [FixedShortcut] = [
        FixedShortcut(keys: "Space", title: "Temporary Hand (hold)"),
        FixedShortcut(keys: "1 … 0", title: "Brush or Layer Opacity 10 … 100%"),
        FixedShortcut(keys: "⇧ + tool key", title: "Cycle Tools Sharing a Key"),
        FixedShortcut(keys: "← → ↑ ↓", title: "Nudge"),
        FixedShortcut(keys: "⇧ ← → ↑ ↓", title: "Nudge Further"),
        FixedShortcut(keys: "⌫", title: "Delete Layer or Selected Pixels"),
        FixedShortcut(keys: "↩", title: "Commit Crop / Path / Selection"),
        FixedShortcut(keys: "⎋", title: "Cancel / Deselect"),
        FixedShortcut(keys: "⇪", title: "Precise Brush Cursor"),
        FixedShortcut(keys: "⌥ click", title: "Zoom Out / Set Clone Source"),
    ]
}

// MARK: - Store

/// Current bindings: defaults plus the user's overrides, in UserDefaults.
@Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    nonisolated static let defaultsKey = "keyboardShortcuts.v1"

    private struct Stored: Codable {
        var bound: [String: KeyCombo] = [:]
        var cleared: [String] = []
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var stored: Stored
    @ObservationIgnored private var lookupCache: [KeyCombo: [ShortcutAction]]?

    /// Combos owned by the system or by fixed document commands.
    static let reserved: [KeyCombo: String] = [
        KeyCombo("q", "⌘"): "Quit", KeyCombo("w", "⌘"): "Close", KeyCombo("s", "⌘"): "Save",
        KeyCombo("s", "⇧⌘"): "Save As", KeyCombo("o", "⌘"): "Open", KeyCombo("z", "⌘"): "Undo",
        KeyCombo("z", "⇧⌘"): "Redo", KeyCombo("c", "⌘"): "Copy", KeyCombo("v", "⌘"): "Paste",
        KeyCombo("x", "⌘"): "Cut", KeyCombo("h", "⌘"): "Hide App", KeyCombo("h", "⌥⌘"): "Hide Others",
        KeyCombo("m", "⌘"): "Minimize", KeyCombo(",", "⌘"): "Settings", KeyCombo("p", "⌘"): "Print",
        KeyCombo("f", "⌃⌘"): "Full Screen", KeyCombo("space"): "Temporary Hand",
        KeyCombo("delete"): "Delete", KeyCombo("escape"): "Cancel", KeyCombo("return"): "Commit",
        KeyCombo("left"): "Nudge", KeyCombo("right"): "Nudge", KeyCombo("up"): "Nudge", KeyCombo("down"): "Nudge",
    ]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    func combo(for action: ShortcutAction) -> KeyCombo? {
        if let bound = stored.bound[action.rawValue] { return bound }
        if stored.cleared.contains(action.rawValue) { return nil }
        return action.defaultCombo
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        combo(for: action) != action.defaultCombo
    }

    var hasCustomizations: Bool { ShortcutAction.allCases.contains(where: isCustomized) }

    /// Menu form; nil for single-key bindings (the canvas handles those).
    func menuShortcut(_ action: ShortcutAction) -> KeyboardShortcut? {
        guard let combo = combo(for: action), combo.isMenuEligible else { return nil }
        return combo.keyboardShortcut
    }

    /// Short " (B)" suffix for tooltips.
    func hint(_ action: ShortcutAction) -> String {
        guard Preferences.shared.showsShortcutsInTooltips, let combo = combo(for: action) else { return "" }
        return " (\(combo.displayString))"
    }

    func actions(for combo: KeyCombo) -> [ShortcutAction] {
        if lookupCache == nil {
            var table: [KeyCombo: [ShortcutAction]] = [:]
            for action in ShortcutAction.allCases {
                if let bound = self.combo(for: action) { table[bound, default: []].append(action) }
            }
            lookupCache = table
        }
        return lookupCache?[combo] ?? []
    }

    /// Other actions already using `combo`. Tools may share a key (pressing
    /// it cycles them), so tool–tool overlaps don't count.
    func conflicts(for combo: KeyCombo, excluding action: ShortcutAction) -> [ShortcutAction] {
        actions(for: combo).filter { other in
            other != action && !(other.tool != nil && action.tool != nil)
        }
    }

    /// Binds `combo` (nil clears). Returns the actions it was taken from.
    @discardableResult
    func set(_ combo: KeyCombo?, for action: ShortcutAction) -> [ShortcutAction] {
        var removed: [ShortcutAction] = []
        if let combo {
            removed = conflicts(for: combo, excluding: action)
            for other in removed { assign(nil, to: other) }
        }
        assign(combo, to: action)
        save()
        return removed
    }

    func reset(_ action: ShortcutAction) {
        if let combo = action.defaultCombo {
            for other in conflicts(for: combo, excluding: action) { assign(nil, to: other) }
        }
        assign(action.defaultCombo, to: action)
        save()
    }

    func resetAll() {
        stored = Stored()
        save()
    }

    private func assign(_ combo: KeyCombo?, to action: ShortcutAction) {
        stored.bound[action.rawValue] = nil
        stored.cleared.removeAll { $0 == action.rawValue }
        if combo != action.defaultCombo {
            if let combo { stored.bound[action.rawValue] = combo } else { stored.cleared.append(action.rawValue) }
        }
        lookupCache = nil
    }

    private func save() {
        lookupCache = nil
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}
