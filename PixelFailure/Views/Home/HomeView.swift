import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The launch / Home window: start a new canvas, pick a preset, or reopen
/// recent work. One instance, opened at launch and from File > New.
struct HomeView: View {
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Bindable private var home = HomeModel.shared
    @State private var isDropTargeted = false
    @State private var didCheckLaunch = false

    private var launcher: DocumentLauncher {
        DocumentLauncher(newDocument: newDocument, openDocument: openDocument) {
            dismissWindow(id: HomeModel.windowID)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            HomeSidebar(section: $home.section, openFile: launcher.presentOpenPanel)
            Group {
                switch home.section {
                case .home:
                    HomeOverview(launcher: launcher)
                case .new:
                    NewDocumentPane(launcher: launcher) {
                        dismissWindow(id: HomeModel.windowID)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1100, height: 700)
        .background(Theme.canvas)
        .foregroundStyle(Theme.text)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.accent, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            loadDroppedURLs(providers)
            return true
        }
        .onAppear {
            home.openWindow = openWindow
            RecentFilesStore.shared.refresh()
            // At launch the window is presented even when documents were
            // restored; Home is only for an empty session.
            if !didCheckLaunch {
                didCheckLaunch = true
                if !NSDocumentController.shared.documents.isEmpty {
                    dismissWindow(id: HomeModel.windowID)
                }
            }
        }
    }

    private func loadDroppedURLs(_ providers: [NSItemProvider]) {
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in launcher.open([url]) }
            }
        }
    }
}

// MARK: - Sidebar

private struct HomeSidebar: View {
    @Binding var section: HomeSection
    let openFile: () -> Void
    @AppStorage(LaunchAction.defaultsKey) private var launchAction: LaunchAction = .home

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                Text("PixelFailure")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.top, 48)
            .padding(.bottom, 22)

            SidebarRow(title: "Home", icon: "house", isSelected: section == .home) {
                section = .home
            }
            SidebarRow(title: "New Document", icon: "plus.square", isSelected: section == .new) {
                HomeModel.shared.draft.name = "Untitled"
                section = .new
            }
            SidebarRow(title: "Open…", icon: "folder", isSelected: false, action: openFile)

            Spacer()

            VStack(alignment: .leading, spacing: 5) {
                Text("On Launch")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textFaint)
                Picker("On Launch", selection: $launchAction) {
                    ForEach(LaunchAction.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .help("Blank Canvas opens a document with the last used size and settings")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Theme.header)
        .hairline(.trailing)
    }
}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Theme.text : Theme.icon)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.text : Theme.textDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(isSelected ? Theme.rowSelected : (isHovering ? Theme.hover : .clear),
                        in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Home overview

private struct HomeOverview: View {
    let launcher: DocumentLauncher
    @State private var recents = RecentFilesStore.shared
    @State private var search = ""

    private static let quickPresetIDs = ["music.Album Cover", "social.Square Post",
                                         "social.Story / Reel"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                Text("Home")
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.top, 14)

                VStack(alignment: .leading, spacing: 12) {
                    SectionTitle("Quick Start")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            blankCanvasTile
                            ForEach(quickPresets) { preset in
                                FormatTile(title: preset.name,
                                           subtitle: preset.settings.dimensionSummary,
                                           size: preset.settings.pixelSize) {
                                    launcher.create(NewDocumentStore.shared.lastUsed
                                        .applyingFormat(of: preset.settings))
                                }
                            }
                            moreTile
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        SectionTitle("Recent")
                        Spacer()
                        if !recents.files.isEmpty {
                            SearchField(text: $search)
                            Button("Clear") { recents.clear() }
                                .buttonStyle(.plain)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textDim)
                                .help("Clear the recent files list")
                        }
                    }
                    recentGrid
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
    }

    private var quickPresets: [DocumentPreset] {
        let all = PresetCategory.allCases.flatMap(DocumentPreset.builtIn)
        return Self.quickPresetIDs.compactMap { id in all.first { $0.id == id } }
    }

    private var blankCanvasTile: some View {
        let last = NewDocumentStore.shared.lastUsed
        return FormatTile(title: "Blank Canvas", subtitle: last.dimensionSummary,
                          size: last.pixelSize, isPrimary: true) {
            var blank = last
            blank.name = "Untitled"
            blank.starterGenerator = nil
            launcher.create(blank)
        }
        .help("New empty document at the last used size and settings")
    }

    private var moreTile: some View {
        FormatTile(title: "More Presets", subtitle: "Size, color, content", size: nil) {
            HomeModel.shared.draft.name = "Untitled"
            HomeModel.shared.section = .new
        }
    }

    private var filteredFiles: [RecentFile] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return recents.files }
        return recents.files.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    @ViewBuilder
    private var recentGrid: some View {
        if recents.files.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(Theme.textFaint)
                Text("No recent files")
                    .foregroundStyle(Theme.textDim)
                Text("Drop an image or project here to open it")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .background(Theme.panel.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Theme.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 18)],
                      alignment: .leading, spacing: 22) {
                ForEach(filteredFiles) { file in
                    RecentFileCard(file: file,
                                   thumbnail: recents.thumbnails[file.url],
                                   detail: recents.details[file.url]) {
                        launcher.open([file.url])
                    }
                }
            }
        }
    }
}

struct SectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Theme.textDim)
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textFaint)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 7)
        .frame(width: 180, height: 22)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.fieldBorder, lineWidth: 1))
    }
}

/// A clickable document-format card: an aspect-true outline of the canvas,
/// its name, and its dimensions.
struct FormatTile: View {
    let title: String
    let subtitle: String
    let size: CGSize?
    var isPrimary = false
    var isSelected = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) { tile }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
    }

    private var tile: some View {
        VStack(spacing: 10) {
            ZStack {
                if let size {
                    AspectGlyph(size: size, highlighted: isPrimary || isSelected)
                } else {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.icon)
                }
            }
            .frame(height: 62)

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 148, height: 132)
        .background(isSelected ? Theme.rowSelected : (isHovering ? Theme.hover : Theme.panel),
                    in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Theme.accent : (isHovering ? Theme.fieldBorder : Theme.border),
                              lineWidth: isSelected ? 2 : 1)
        )
        .contentShape(Rectangle())
    }
}

/// The canvas proportions drawn as an outlined page.
struct AspectGlyph: View {
    let size: CGSize
    var highlighted = false
    var box: CGFloat = 52

    var body: some View {
        let aspect = size.width / max(size.height, 1)
        let width = aspect >= 1 ? box : max(box * aspect, 10)
        let height = aspect >= 1 ? max(box / aspect, 10) : box
        RoundedRectangle(cornerRadius: 2)
            .fill(highlighted ? Theme.accent.opacity(0.14) : Theme.field)
            .overlay(RoundedRectangle(cornerRadius: 2)
                .strokeBorder(highlighted ? Theme.accent : Theme.icon.opacity(0.7), lineWidth: 1.5))
            .frame(width: width, height: height)
    }
}
