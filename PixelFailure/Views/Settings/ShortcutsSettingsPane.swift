import AppKit
import SwiftUI

/// Searchable list of every rebindable command, grouped by menu.
struct ShortcutsSettingsPane: View {
    @State private var query = ""
    @State private var category: ShortcutCategory?
    @State private var recording: ShortcutAction?
    /// A short note under one row: what was replaced, or why a key was refused.
    @State private var note: (action: ShortcutAction, text: String, isWarning: Bool)?

    private var store: ShortcutStore { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.textFaint)
                    TextField("Search commands or keys", text: $query)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 7)
                .frame(width: 240, height: 22)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.fieldBorder, lineWidth: 1))

                Picker("Category", selection: $category) {
                    Text("All Commands").tag(ShortcutCategory?.none)
                    Divider()
                    ForEach(ShortcutCategory.allCases) { Text($0.rawValue).tag(Optional($0)) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .padding(.horizontal, 24)
            .frame(height: 40)
            .hairline(.bottom)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    ForEach(visibleCategories, id: \.0) { category, actions in
                        Section {
                            ForEach(actions) { row($0) }
                        } header: {
                            sectionHeader(category.rawValue)
                        }
                    }
                    if category == nil, !fixedRows.isEmpty {
                        Section {
                            ForEach(fixedRows) { fixed in
                                HStack {
                                    Text(fixed.title).foregroundStyle(Theme.textDim)
                                    Spacer()
                                    Text(fixed.keys)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Theme.textDim)
                                        .frame(width: 150, alignment: .center)
                                    Color.clear.frame(width: 22)
                                }
                                .padding(.horizontal, 24)
                                .frame(height: 26)
                            }
                        } header: {
                            sectionHeader("Canvas (Fixed)")
                        }
                    }
                }
                .padding(.bottom, 16)
            }
        }
        .onChange(of: recording) { _, _ in
            if recording != nil { note = nil }
        }
        // Restore Defaults (in the window header) makes any note stale.
        .onChange(of: store.hasCustomizations) { _, customized in
            if !customized { note = nil }
        }
    }

    // MARK: Rows

    private func row(_ action: ShortcutAction) -> some View {
        let combo = store.combo(for: action)
        let customized = store.isCustomized(action)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(action.title)
                    .foregroundStyle(Theme.text)
                if customized {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        .help("Changed from default (\(action.defaultCombo?.displayString ?? "none"))")
                }
                Spacer()
                ShortcutRecorder(combo: combo, isRecording: Binding(
                    get: { recording == action },
                    set: { recording = $0 ? action : nil }
                )) { result in
                    handle(result, for: action)
                }
                Button {
                    store.reset(action)
                    note = nil
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(IconButtonStyle(size: 22))
                .opacity(customized ? 1 : 0)
                .disabled(!customized)
                .help("Restore Default")
            }
            if let note, note.action == action {
                Text(note.text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(note.isWarning ? Theme.warning : Theme.textDim)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 30)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 3)
        .frame(minHeight: 26)
        .background(recording == action ? Theme.hover : .clear)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.headerFont)
            .foregroundStyle(Theme.textDim)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(Theme.panel)
            .hairline(.bottom)
    }

    // MARK: Recording

    private func handle(_ result: ShortcutRecorder.Result, for action: ShortcutAction) {
        recording = nil
        switch result {
        case .cancelled:
            break
        case .cleared:
            store.set(nil, for: action)
            note = nil
        case .combo(let combo):
            if let reason = ShortcutStore.reserved[combo], combo != action.defaultCombo {
                note = (action, "\(combo.displayString) is reserved for \(reason)", true)
                return
            }
            if action.isAppLevel && !combo.isMenuEligible {
                note = (action, "Needs ⌘ or ⌃", true)
                return
            }
            let replaced = store.set(combo, for: action)
            if !replaced.isEmpty {
                let names = replaced.map { "\($0.category.rawValue) › \($0.title)" }.joined(separator: ", ")
                note = (action, "Removed from \(names)", false)
            } else {
                note = nil
            }
        }
    }

    // MARK: Filtering

    private var visibleCategories: [(ShortcutCategory, [ShortcutAction])] {
        let categories = category.map { [$0] } ?? ShortcutCategory.allCases
        return categories.compactMap { category in
            let actions = ShortcutAction.allCases.filter { $0.category == category && matches($0) }
            return actions.isEmpty ? nil : (category, actions)
        }
    }

    private var fixedRows: [FixedShortcut] {
        FixedShortcut.all.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
            || $0.keys.localizedCaseInsensitiveContains(query) }
    }

    private func matches(_ action: ShortcutAction) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return true }
        if action.title.localizedCaseInsensitiveContains(trimmed) { return true }
        if action.category.rawValue.localizedCaseInsensitiveContains(trimmed) { return true }
        guard let combo = store.combo(for: action) else { return false }
        return combo.displayString.localizedCaseInsensitiveContains(trimmed)
    }
}

/// Click, then press the new keys. ⎋ cancels, ⌫ clears.
struct ShortcutRecorder: View {
    enum Result { case combo(KeyCombo), cleared, cancelled }

    let combo: KeyCombo?
    @Binding var isRecording: Bool
    let onResult: (Result) -> Void

    @State private var monitor: Any?
    @State private var isHovering = false

    var body: some View {
        Button {
            isRecording.toggle()
        } label: {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isRecording ? Theme.accent : (combo == nil ? Theme.textFaint : Theme.text))
                .frame(width: 150, height: 20)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(isRecording ? Theme.accent : (isHovering ? Theme.textFaint : Theme.fieldBorder),
                            lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isRecording ? "⎋ cancels · ⌫ clears" : "Click to change")
        .onChange(of: isRecording) { _, recording in
            recording ? startMonitoring() : stopMonitoring()
        }
        .onDisappear { stopMonitoring() }
    }

    private var label: String {
        if isRecording { return "Type shortcut…" }
        return combo?.displayString ?? "—"
    }

    private func startMonitoring() {
        stopMonitoring()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard event.type == .keyDown else {
                    // Clicking elsewhere ends recording.
                    finish(.cancelled)
                    return false
                }
                guard let combo = KeyCombo(event: event) else { return true }
                if combo == KeyCombo("escape") {
                    finish(.cancelled)
                } else if combo == KeyCombo("delete") {
                    finish(.cleared)
                } else {
                    finish(.combo(combo))
                }
                return true
            }
            return consumed ? nil : event
        }
    }

    private func finish(_ result: Result) {
        stopMonitoring()
        isRecording = false
        onResult(result)
    }

    private func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
