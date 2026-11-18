import AppKit
import SwiftUI

/// Design tokens for the editor chrome. A neutral charcoal "pro" palette in
/// the Photoshop / Affinity mould: panels sit one step above a darker canvas
/// surround, regions are split by near-black hairlines, and a single blue
/// accent marks focus and active state. The app always runs dark.
enum Theme {
    private static func hex(_ value: UInt32) -> Color {
        Color(.sRGB,
              red: Double((value >> 16) & 0xFF) / 255,
              green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255,
              opacity: 1)
    }

    // Surfaces
    static let panel = hex(0x2E2E2E)
    static let chrome = hex(0x2E2E2E)
    static let header = hex(0x262626)
    static let canvas = hex(0x1E1E1E)
    static let border = hex(0x181818)
    static let separator = hex(0x3A3A3A)
    static let field = hex(0x222222)
    static let fieldBorder = hex(0x464646)

    // Interaction
    static let hover = hex(0x3A3A3A)
    static let pressed = hex(0x474747)
    static let rowSelected = hex(0x484848)
    static let toolActive = hex(0x4A4A4A)

    // Content
    static let text = hex(0xE2E2E2)
    static let textDim = hex(0xA4A4A4)
    static let textFaint = hex(0x6C6C6C)
    static let icon = hex(0xC4C4C4)

    static let accent = hex(0x378EF0)
    /// The accent as a CGColor, for bitmap overlays (smart-selection tints).
    nonisolated static let accentCG = CGColor(srgbRed: 0x37 / 255.0, green: 0x8E / 255.0,
                                              blue: 0xF0 / 255.0, alpha: 1)
    static let warning = hex(0xE8B046)
    /// Magenta, as in Photoshop/Affinity, so guides read on any artwork.
    static let smartGuide = hex(0xFF3EBF)

    // Metrics
    static let labelWidth: CGFloat = 86
    static let panelFont = Font.system(size: 11)
    static let headerFont = Font.system(size: 11, weight: .semibold)
}

// MARK: - Panel environment

extension View {
    /// Compact controls, small type, and aligned label/value rows — applied
    /// once at the root of every dock panel and the options bar.
    func panelStyle() -> some View {
        self
            .font(Theme.panelFont)
            .controlSize(.small)
            .toggleStyle(.checkbox)
            .labeledContentStyle(PanelLabeledContentStyle())
            .foregroundStyle(Theme.text)
    }

    /// A 1pt near-black hairline on one edge, used between regions.
    func hairline(_ edge: Edge) -> some View {
        overlay(alignment: edge.alignment) {
            Rectangle()
                .fill(Theme.border)
                .frame(width: edge.isHorizontal ? 1 : nil, height: edge.isHorizontal ? nil : 1)
        }
    }
}

private extension Edge {
    var isHorizontal: Bool { self == .leading || self == .trailing }
    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }
}

/// Fixed-width dim label on the left, control filling the rest.
struct PanelLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 8) {
            configuration.label
                .foregroundStyle(Theme.textDim)
                .lineLimit(1)
                .frame(width: Theme.labelWidth, alignment: .leading)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 22)
    }
}

// MARK: - Sections

/// A collapsible inspector section: a slim title row with a chevron, then
/// the rows. Collapsed state is remembered per title.
struct InspectorSection<Content: View, Accessory: View>: View {
    let title: String
    @AppStorage private var isExpanded: Bool
    private let accessory: Accessory
    private let content: Content

    init(_ title: String,
         @ViewBuilder content: () -> Content,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        _isExpanded = AppStorage(wrappedValue: true, "inspector.section.\(title)")
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textFaint)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Text(title)
                    .font(Theme.headerFont)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                accessory
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    content
                }
                .padding(.leading, 12)
                .padding(.trailing, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, content: content, accessory: { EmptyView() })
    }
}

// MARK: - Labeled controls

/// A popup with its label in the panel's label column.
struct PanelPicker<SelectionValue: Hashable, Content: View>: View {
    let title: String
    @Binding var selection: SelectionValue
    let content: () -> Content

    init(_ title: String, selection: Binding<SelectionValue>,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        _selection = selection
        self.content = content
    }

    var body: some View {
        LabeledContent(title) {
            Picker(title, selection: $selection, content: content)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A color well with its label in the panel's label column.
struct PanelColorPicker: View {
    let title: String
    @Binding var selection: Color

    init(_ title: String, selection: Binding<Color>) {
        self.title = title
        _selection = selection
    }

    var body: some View {
        LabeledContent(title) {
            ColorPicker(title, selection: $selection)
                .labelsHidden()
                .frame(width: 44)
        }
    }
}

/// A compact numeric text box (Photoshop-style value field).
struct PanelNumberField: View {
    let label: String?
    @Binding var value: Double
    var fractionDigits = 0
    var width: CGFloat = 56

    var body: some View {
        HStack(spacing: 3) {
            if let label {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textFaint)
            }
            TextField(label ?? "", value: $value,
                      format: .number.precision(.fractionLength(0...fractionDigits)).grouping(.never))
                .textFieldStyle(.plain)
                .font(.system(size: 11).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 5)
                .frame(width: width, height: 20)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.fieldBorder, lineWidth: 1))
        }
    }
}

// MARK: - Panel chrome

/// Tab strip across the top of a dock panel.
struct PanelTabBar<Tab: Hashable>: View {
    let tabs: [(Tab, String)]
    @Binding var selection: Tab
    var trailing: AnyView? = nil

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.0) { tab, title in
                let isSelected = tab == selection
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.text : Theme.textDim)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity)
                    .background(isSelected ? Theme.panel : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { selection = tab }
            }
            Spacer(minLength: 0)
            if let trailing { trailing.padding(.trailing, 8) }
        }
        .frame(height: 26)
        .background(Theme.header)
        .hairline(.bottom)
    }
}

/// Single-title header for a panel without tabs.
struct PanelHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(maxHeight: .infinity)
                .background(Theme.panel)
            Spacer(minLength: 0)
            trailing.padding(.trailing, 8)
        }
        .frame(height: 26)
        .background(Theme.header)
        .hairline(.bottom)
    }
}

/// Borderless square icon button with hover and pressed fills.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 24
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, isActive: isActive)
    }

    private struct IconButtonBody: View {
        let configuration: Configuration
        let size: CGFloat
        let isActive: Bool
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .foregroundStyle(isActive ? Theme.text : Theme.icon)
                .frame(width: size, height: size)
                .background(fill, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { isHovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Theme.pressed }
            if isActive { return Theme.toolActive }
            if isHovering && isEnabled { return Theme.hover }
            return .clear
        }
    }
}

/// Thin vertical divider for horizontal bars.
struct BarDivider: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(width: 1, height: 18)
    }
}
