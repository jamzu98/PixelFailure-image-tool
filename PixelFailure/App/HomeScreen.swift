import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// What happens when the app launches with no documents to restore.
enum LaunchAction: String, CaseIterable {
    case home, blankCanvas

    nonisolated static let defaultsKey = "home.launchAction"

    var displayName: String {
        switch self {
        case .home: "Home Screen"
        case .blankCanvas: "Blank Canvas"
        }
    }

    nonisolated static var current: LaunchAction {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(LaunchAction.init) ?? .home
    }
}

enum HomeSection: Hashable {
    case home, new
}

/// Shared state for the single Home window, so menu commands and the app
/// delegate can open it on a given section.
@Observable
final class HomeModel {
    static let shared = HomeModel()
    static let windowID = "home"

    var section: HomeSection = .home
    /// The New Document dialog's working settings; survives section switches.
    var draft: NewDocumentSettings
    var selectedPresetID: String?
    var category: PresetCategory
    /// Captured from the Home view so AppKit callbacks can reopen it.
    @ObservationIgnored var openWindow: OpenWindowAction?

    private init() {
        draft = NewDocumentStore.shared.lastUsed
        category = NewDocumentStore.shared.recent.isEmpty ? .music : .recent
    }

    func show(_ section: HomeSection, using openWindow: OpenWindowAction? = nil) {
        self.section = section
        if section == .new { draft.name = "Untitled" }
        (openWindow ?? self.openWindow)?(id: Self.windowID)
    }
}

// MARK: - Remembered settings

/// Last-used, recent, and saved New Document settings, in UserDefaults.
@Observable
final class NewDocumentStore {
    static let shared = NewDocumentStore()

    nonisolated private static let lastUsedKey = "newDocument.lastUsed"
    private static let recentKey = "newDocument.recent"
    private static let savedKey = "newDocument.saved"
    private static let recentLimit = 8

    private(set) var lastUsed: NewDocumentSettings
    private(set) var recent: [NewDocumentSettings]
    private(set) var saved: [NewDocumentSettings]

    private init() {
        lastUsed = Self.loadLastUsed()
        recent = Self.load(Self.recentKey) ?? []
        saved = Self.load(Self.savedKey) ?? []
    }

    /// Readable from the nonisolated DocumentGroup factory.
    nonisolated static func loadLastUsed() -> NewDocumentSettings {
        load(lastUsedKey) ?? NewDocumentSettings()
    }

    func recordUse(_ settings: NewDocumentSettings) {
        lastUsed = settings
        recent.removeAll { $0.hasSameFormat(as: settings) && $0.name == settings.name }
        recent.insert(settings, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        Self.store(lastUsed, Self.lastUsedKey)
        Self.store(recent, Self.recentKey)
    }

    func savePreset(_ settings: NewDocumentSettings) {
        saved.removeAll { $0.name == settings.name }
        saved.append(settings)
        Self.store(saved, Self.savedKey)
    }

    func remove(_ settings: NewDocumentSettings, from category: PresetCategory) {
        switch category {
        case .saved:
            saved.removeAll { $0 == settings }
            Self.store(saved, Self.savedKey)
        case .recent:
            recent.removeAll { $0 == settings }
            Self.store(recent, Self.recentKey)
        default:
            break
        }
    }

    func presets(in category: PresetCategory) -> [DocumentPreset] {
        switch category {
        case .recent:
            recent.enumerated().map { DocumentPreset(id: "recent.\($0.offset)", settings: $0.element) }
        case .saved:
            saved.enumerated().map { DocumentPreset(id: "saved.\($0.offset)", settings: $0.element) }
        default:
            DocumentPreset.builtIn(category)
        }
    }

    nonisolated private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func store<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

// MARK: - Creating and opening documents

/// Creates and opens documents through SwiftUI's document actions, so every
/// path (Home screen, menus, drops) ends up in a regular DocumentGroup window.
struct DocumentLauncher {
    let newDocument: NewDocumentAction
    let openDocument: OpenDocumentAction
    var onOpen: () -> Void = {}

    static var openableTypes: [UTType] {
        var types: [UTType] = [.pixelFailureProject, .image]
        if let psd = UTType(filenameExtension: "psd") { types.append(psd) }
        return types
    }

    func create(_ settings: NewDocumentSettings) {
        NewDocumentStore.shared.recordUse(settings)
        present(PixelDocument(model: settings.makeModel()), named: settings.name)
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.openableTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        open(panel.urls)
    }

    func open(_ urls: [URL]) {
        var opened = false
        for url in urls {
            // Projects are packages, so a plain UTType(filenameExtension:)
            // lookup (which assumes public.data) never resolves them.
            if url.pathExtension.lowercased() == "pixelfailure" {
                opened = true
                Task {
                    do { try await openDocument(at: url) } catch { NSSound.beep() }
                }
            } else if openImage(at: url) {
                opened = true
            }
        }
        if opened { onOpen() } else if !urls.isEmpty { NSSound.beep() }
    }

    /// Photoshop-style: an image file opens as a new canvas of its own size
    /// holding the image as a layer.
    private func openImage(at url: URL) -> Bool {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              let format = Self.imageFormat(data: data, fileExtension: url.pathExtension) else { return false }

        let name = url.deletingPathExtension().lastPathComponent
        var settings = NewDocumentStore.shared.lastUsed
        settings.name = name
        settings.width = format.size.width
        settings.height = format.size.height
        settings.dpi = format.dpi
        settings.unit = .pixels
        settings.starterGenerator = nil
        settings.guides = .none

        let document = PixelDocument(model: settings.makeModel())
        guard document.importAsset(data: data, fileExtension: url.pathExtension,
                                   suggestedName: name, undoManager: nil) != nil else { return false }
        present(document, named: name)
        return true
    }

    private static func imageFormat(data: Data, fileExtension: String) -> (size: CGSize, dpi: Double)? {
        if fileExtension.lowercased() == "psd", let decoded = try? PSDImporter.decode(data) {
            return (decoded.size, 72)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double,
              width > 0, height > 0 else { return nil }
        var size = CGSize(width: width, height: height)
        // EXIF orientations 5–8 are rotated a quarter turn.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            size = CGSize(width: height, height: width)
        }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        return (size, dpi)
    }

    /// Opens an unsaved document's recovery archive in a window of its own.
    func openRecovered(_ archive: RecoveryArchive) {
        // Marked edited: it exists nowhere else, so closing it must ask to save.
        present(PixelDocument.recovered(from: archive), named: "Recovered", markEdited: true)
    }

    private func present(_ document: PixelDocument, named name: String, markEdited: Bool = false) {
        let before = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
        newDocument { document }
        Self.configureNewDocument(named: name, markEdited: markEdited, excluding: before)
        onOpen()
    }

    /// SwiftUI has no hook for an untitled document's name or edited state;
    /// set them on the backing NSDocument so the title bar, the first Save
    /// panel and the close prompt use them.
    private static func configureNewDocument(named name: String, markEdited: Bool,
                                             excluding before: Set<ObjectIdentifier>) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let rename = !trimmed.isEmpty && trimmed != "Untitled"
        guard rename || markEdited else { return }
        func apply() -> Bool {
            guard let document = NSDocumentController.shared.documents.first(where: {
                !before.contains(ObjectIdentifier($0))
            }) else { return false }
            if rename {
                document.displayName = trimmed
                document.windowControllers.forEach { $0.synchronizeWindowTitleWithDocumentName() }
            }
            if markEdited { document.updateChangeCount(.changeDone) }
            return true
        }
        if apply() { return }
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(30))
                if apply() { return }
            }
        }
    }
}

// MARK: - Files from Finder

/// Images handed over by Finder (Open With, Dock drops, `open -a`) open as
/// canvases through the same launcher as File > Open Image as Canvas. The
/// launcher needs SwiftUI's document actions, so URLs that arrive during
/// launch wait until the menu commands install it.
final class ExternalOpenRouter {
    static let shared = ExternalOpenRouter()

    private var launcher: DocumentLauncher?
    private var pending: [URL] = []

    func install(_ launcher: DocumentLauncher) {
        let isFirst = self.launcher == nil
        self.launcher = launcher
        guard isFirst, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        // Installed from a Commands body; present documents outside it.
        Task { @MainActor in launcher.open(urls) }
    }

    func open(_ urls: [URL]) {
        if let launcher { launcher.open(urls) } else { pending += urls }
    }
}

// MARK: - App delegate

/// Routes launch, Dock reopen, and last-window-closed to the Home screen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var closeObserver: Any?

    /// Implementing this takes over AppKit's default, which would hand every
    /// URL to NSDocumentController; only projects are PixelDocuments.
    func application(_ application: NSApplication, open urls: [URL]) {
        let projects = urls.filter { $0.pathExtension.lowercased() == "pixelfailure" }
        let images = urls.filter { $0.pathExtension.lowercased() != "pixelfailure" }
        for url in projects {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if error != nil { NSSound.beep() }
            }
        }
        if !images.isEmpty { ExternalOpenRouter.shared.open(images) }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        LaunchAction.current == .blankCanvas && !hasLaunched
    }

    private var hasLaunched = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let window = note.object as? NSWindow
            MainActor.assumeIsolated { self?.windowWillClose(window) }
        }
        Task { @MainActor in
            // After launch, untitled-file requests come from Dock reopen,
            // which goes to Home instead.
            try? await Task.sleep(for: .seconds(1))
            hasLaunched = true
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        HomeModel.shared.show(.home)
        return false
    }

    private func windowWillClose(_ window: NSWindow?) {
        guard let window, let closing = NSDocumentController.shared.document(for: window) else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            let remaining = NSDocumentController.shared.documents.filter { $0 !== closing }
            if remaining.isEmpty { HomeModel.shared.show(.home) }
        }
    }
}
