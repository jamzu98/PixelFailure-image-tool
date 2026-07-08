import SwiftUI

@main
struct PixelFailureApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: { PixelDocument() }) { configuration in
            EditorView(document: configuration.document)
        }
    }
}
