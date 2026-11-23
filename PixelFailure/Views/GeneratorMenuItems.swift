import SwiftUI

/// Generators for menus and pickers, grouped (originals, newer vector
/// generators, GPU raster generators) with dividers between groups.
struct GeneratorMenuItems<Content: View>: View {
    var filter: (GeneratorType) -> Bool = { _ in true }
    @ViewBuilder let content: (GeneratorType) -> Content

    var body: some View {
        let groups = GeneratorType.groups.map { $0.filter(filter) }.filter { !$0.isEmpty }
        ForEach(groups.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(groups[index], id: \.self) { content($0) }
        }
    }
}
