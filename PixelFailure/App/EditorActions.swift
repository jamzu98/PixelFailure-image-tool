import AppKit
import SwiftUI

/// The single implementation of every document command, shared by the menu
/// bar and the keyboard router so a shortcut and its menu item always agree.
enum EditorActions {
    // MARK: Availability

    static func canPerform(_ action: ShortcutAction, _ focus: EditorFocus?) -> Bool {
        guard let focus else { return false }
        let state = focus.editorState
        let model = focus.document.model
        let hasLayer = state.selectedLayerID != nil
        let hasLayers = !state.selectedLayerIDs.isEmpty
        let hasSelection = state.selection != nil

        if action.tool != nil { return true }
        switch action {
        case .brushSmaller, .brushLarger, .brushSofter, .brushHarder:
            return state.activeTool.isPaintTool
        case .defaultColors, .swapColors, .export, .togglePanels, .zoomIn, .zoomOut, .fitOnScreen,
             .actualPixels, .toggleRulers, .toggleGrid, .toggleGuides, .toggleSnap, .toggleSmartGuides,
             .toggleNavigator, .selectAll, .selectSubject, .newLayer, .selectLayerAbove, .selectLayerBelow:
            return true
        case .selectAllLayers:
            return !model.layers.isEmpty
        case .resetViewRotation:
            return state.canvasRotationDegrees != 0
        case .clearGuides:
            return !model.workspace.guides.isEmpty
        case .fillForeground, .fillBackground:
            return hasSelection && selectedImageLayer(focus) != nil
        case .freeTransform:
            return hasLayers
        case .deselectLayers:
            return hasLayers
        case .reroll, .randomize:
            return selectedPatternLayerID(focus) != nil
        case .deselect, .invertSelection:
            return hasSelection
        case .reselect:
            return state.lastSelection != nil && !hasSelection
        case .duplicateLayer, .lockLayer, .toggleVisibility, .flipHorizontal, .flipVertical,
             .rasterize, .deleteLayer, .clippingMask:
            return hasLayer
        case .bringForward, .sendBackward, .bringToFront, .sendToBack:
            return hasLayer && !model.isEffectivelyLocked(state.selectedLayerID!)
        case .groupLayers:
            return hasLayers
        case .ungroup:
            return model.layer(id: state.selectedLayerID)?.kind.isGroup == true
        default:
            return false
        }
    }

    // MARK: Perform

    static func perform(_ action: ShortcutAction, _ focus: EditorFocus) {
        let document = focus.document
        let state = focus.editorState
        let undo = focus.undoManager
        let store = focus.renderStore

        if let tool = action.tool {
            select(tool, state)
            return
        }

        switch action {
        // Painting
        case .brushSmaller: state.brush.stepSize(larger: false)
        case .brushLarger: state.brush.stepSize(larger: true)
        case .brushSofter: state.brush.hardness = max(0, ((state.brush.hardness - 0.25) * 4).rounded() / 4)
        case .brushHarder: state.brush.hardness = min(1, ((state.brush.hardness + 0.25) * 4).rounded() / 4)
        case .defaultColors:
            if state.editingMaskLayerID != nil { state.maskBrushReveals = false } else { state.brush.resetColors() }
        case .swapColors:
            // While painting a mask, X flips between hiding and revealing.
            if state.editingMaskLayerID != nil { state.maskBrushReveals.toggle() } else { state.brush.swapColors() }

        // File
        case .export: state.showExportSheet = true

        // Edit
        case .fillForeground, .fillBackground:
            guard let selection = state.selection, let layer = selectedImageLayer(focus) else { return }
            let color = action == .fillForeground ? state.brush.color : state.brush.secondaryColor
            document.fillPixels(selection: selection, layerID: layer.id, color: color,
                                renderStore: store, undoManager: undo)
        case .freeTransform:
            select(.move, state)
        case .deselectLayers:
            state.selectedLayerID = nil

        // Generate
        case .reroll, .randomize:
            guard let id = selectedPatternLayerID(focus) else { return }
            let palette = action == .randomize && Preferences.shared.randomizeSwitchesPalette
                ? BuiltInPalettes.all.filter { $0 != document.model.palette }.randomElement() : nil
            document.reroll(layerID: id, randomizeParams: action == .randomize,
                            newPalette: palette, undoManager: undo)

        // Select
        case .selectAll:
            state.selection = .all(canvasSize: document.model.canvasSize)
        case .deselect:
            state.selection = nil
        case .reselect:
            if let last = state.lastSelection { state.selection = last }
        case .invertSelection:
            guard let selection = state.selection else { return }
            state.selection = selection.inverted(canvasSize: document.model.canvasSize)
        case .selectAllLayers:
            state.selectedLayerIDs = Set(document.model.layers.map(\.id))
        case .selectSubject:
            state.vision.selectSubject(inverted: false, focus: focus)

        // Layer
        case .newLayer:
            if let id = document.addPaintLayer(undoManager: undo) { state.selectedLayerID = id }
        case .duplicateLayer:
            // Photoshop's ⌘J: with a pixel selection it copies just that area.
            if let selection = state.selection, let layer = selectedImageLayer(focus),
               let id = document.layerFromSelection(selection, layerID: layer.id,
                                                    renderStore: store, undoManager: undo) {
                state.selectedLayerID = id
            } else if let id = state.selectedLayerID {
                state.selectedLayerID = document.duplicateLayer(id: id, undoManager: undo)
            }
        case .groupLayers:
            if let id = document.groupLayers(ids: state.selectedLayerIDs, undoManager: undo) {
                state.selectedLayerID = id
            }
        case .ungroup:
            guard let id = state.selectedLayerID else { return }
            document.ungroup(id: id, undoManager: undo)
            state.selectedLayerIDs = []
        case .clippingMask:
            guard let id = state.selectedLayerID, let layer = document.model.layer(id: id) else { return }
            document.update(undo, actionName: layer.clipsToBelow ? "Release Clipping Mask" : "Create Clipping Mask") {
                $0.modifyLayer(id: id) { $0.clipsToBelow.toggle() }
            }
        case .lockLayer:
            if let id = state.selectedLayerID { document.toggleLock(id: id, undoManager: undo) }
        case .toggleVisibility:
            guard let id = state.selectedLayerID, let layer = document.model.layer(id: id) else { return }
            document.update(undo, actionName: layer.isVisible ? "Hide Layer" : "Show Layer") {
                $0.modifyLayer(id: id) { $0.isVisible.toggle() }
            }
        case .bringForward, .sendBackward, .bringToFront, .sendToBack:
            guard let id = state.selectedLayerID else { return }
            let offset = switch action {
            case .bringForward: 1
            case .sendBackward: -1
            case .bringToFront: Int.max
            default: Int.min
            }
            document.reorderLayer(id: id, offset: offset, undoManager: undo)
        case .selectLayerAbove, .selectLayerBelow:
            selectAdjacentLayer(above: action == .selectLayerAbove, focus)
        case .flipHorizontal, .flipVertical:
            if let id = state.selectedLayerID {
                document.flipLayer(id: id, horizontally: action == .flipHorizontal, undoManager: undo)
            }
        case .rasterize:
            if let id = state.selectedLayerID {
                document.rasterizeLayer(id: id, renderStore: store, undoManager: undo)
            }
        case .deleteLayer:
            guard !state.selectedLayerIDs.isEmpty else { return }
            document.deleteLayers(ids: state.selectedLayerIDs, undoManager: undo)
            state.selectedLayerIDs = []

        // View
        case .zoomIn: state.viewportCommand = ViewportCommand(kind: .zoomIn)
        case .zoomOut: state.viewportCommand = ViewportCommand(kind: .zoomOut)
        case .fitOnScreen: state.viewportCommand = ViewportCommand(kind: .fit)
        case .actualPixels: state.viewportCommand = ViewportCommand(kind: .actualPixels)
        case .toggleRulers:
            let on = !document.model.workspace.showsRulers
            document.update(undo, actionName: on ? "Show Rulers" : "Hide Rulers") { $0.workspace.showsRulers = on }
        case .toggleGrid:
            let on = !document.model.workspace.grid.isVisible
            document.update(undo, actionName: on ? "Show Grid" : "Hide Grid") { $0.workspace.grid.isVisible = on }
        case .toggleSnap:
            let on = !document.model.workspace.grid.snapsToGrid
            document.update(undo, actionName: "Snap to Grid") { $0.workspace.grid.snapsToGrid = on }
        case .toggleSmartGuides:
            let on = !document.model.workspace.smartGuidesEnabled
            document.update(undo, actionName: "Smart Guides") { $0.workspace.smartGuidesEnabled = on }
        case .toggleNavigator:
            let on = !document.model.workspace.showsNavigator
            document.update(undo, actionName: "Toggle Navigator") { $0.workspace.showsNavigator = on }
        case .toggleGuides:
            state.showsGuides.toggle()
        case .clearGuides:
            document.update(undo, actionName: "Clear Guides") { $0.workspace.guides = [] }
        case .togglePanels:
            withAnimation(.easeOut(duration: 0.15)) { state.panelsHidden.toggle() }
        case .resetViewRotation:
            state.canvasRotationDegrees = 0

        default:
            break
        }
    }

    // MARK: Tools

    /// Switches tools the way the tool strip does.
    static func select(_ tool: EditorTool, _ state: EditorState) {
        state.activeTool = tool
        if tool != .crop { state.cropDraft = nil }
    }

    // MARK: Helpers

    static func selectedImageLayer(_ focus: EditorFocus) -> Layer? {
        guard let layer = focus.document.model.layer(id: focus.editorState.selectedLayerID),
              layer.kind.isImage,
              !focus.document.model.isEffectivelyLocked(layer.id) else { return nil }
        return layer
    }

    static func selectedPatternLayerID(_ focus: EditorFocus) -> UUID? {
        guard let layer = focus.document.model.layer(id: focus.editorState.selectedLayerID),
              layer.kind.isPattern else { return nil }
        return layer.id
    }

    /// ⌥] / ⌥[ — walk the selected layer's siblings, top to bottom.
    private static func selectAdjacentLayer(above: Bool, _ focus: EditorFocus) {
        let model = focus.document.model
        guard let id = focus.editorState.selectedLayerID else {
            // Nothing selected: start at the top (or bottom) of the stack.
            focus.editorState.selectedLayerID = (above ? model.layers.last : model.layers.first)?.id
            return
        }
        let siblings: [Layer]
        if let parentID = model.parentGroupID(of: id),
           case .group(let group) = model.layer(id: parentID)?.kind {
            siblings = group.children
        } else {
            siblings = model.layers
        }
        guard let index = siblings.firstIndex(where: { $0.id == id }) else { return }
        let next = above ? index + 1 : index - 1
        guard siblings.indices.contains(next) else { return }
        focus.editorState.selectedLayerID = siblings[next].id
    }
}
