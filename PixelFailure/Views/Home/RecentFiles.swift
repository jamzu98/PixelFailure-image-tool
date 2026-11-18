import AppKit
import SwiftUI

struct RecentFile: Identifiable, Hashable {
    var url: URL
    var modified: Date?
    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

/// The system recent-documents list plus rendered artwork thumbnails.
/// Thumbnails render from the saved package itself, so they show the real
/// composite rather than a generic file icon.
@Observable
final class RecentFilesStore {
    static let shared = RecentFilesStore()

    private(set) var files: [RecentFile] = []
    private(set) var thumbnails: [URL: NSImage] = [:]
    private(set) var details: [URL: String] = [:]

    @ObservationIgnored private var cacheKeys: [URL: Date] = [:]
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private static let thumbnailSide: Double = 360

    func refresh() {
        let urls = NSDocumentController.shared.recentDocumentURLs
        files = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return RecentFile(url: url, modified: values?.contentModificationDate)
        }
        loadThumbnails()
    }

    func clear() {
        NSDocumentController.shared.clearRecentDocuments(nil)
        files = []
    }

    private func loadThumbnails() {
        loadTask?.cancel()
        let pending = files.filter { file in
            guard thumbnails[file.url] != nil, let cached = cacheKeys[file.url] else { return true }
            return cached != file.modified
        }
        guard !pending.isEmpty else { return }
        loadTask = Task { @MainActor [weak self] in
            for file in pending {
                // Let the window draw first and stay responsive between files.
                await Task.yield()
                guard !Task.isCancelled, let self else { return }
                self.render(file)
            }
        }
    }

    private func render(_ file: RecentFile) {
        let url = file.url
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        cacheKeys[url] = file.modified ?? .distantPast

        guard let document = try? PixelDocument(contentsOf: url) else {
            thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
            return
        }
        let model = document.model
        let size = model.canvasSize
        details[url] = "\(Int(size.width)) × \(Int(size.height))"

        let scale = min(1, Self.thumbnailSide / max(size.width, size.height, 1))
        let target = CGSize(width: max(1, (size.width * scale).rounded()),
                            height: max(1, (size.height * scale).rounded()))
        let store = RenderStore(document: document)
        let items = store.renderItems(model: model, quality: .preview)
        if let image = PNGExporter.render(items: items, background: model.background,
                                          canvasSize: size, targetPixelSize: target,
                                          colorSettings: model.colorSettings.previewVariant) {
            thumbnails[url] = NSImage(cgImage: image, size: target)
        } else {
            thumbnails[url] = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}

struct RecentFileCard: View {
    let file: RecentFile
    let thumbnail: NSImage?
    let detail: String?
    let open: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: open) { card }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(file.url.path)
            .contextMenu {
                Button("Open", action: open)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([file.url])
                }
            }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(Theme.field)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .padding(10)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 136)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(isHovering ? Theme.accent : Theme.border, lineWidth: isHovering ? 2 : 1)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        var parts: [String] = []
        if let detail { parts.append(detail) }
        if let modified = file.modified {
            parts.append(modified.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: "  ·  ")
    }
}
