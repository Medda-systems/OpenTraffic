import SwiftUI

/// Content card for the main window: a title row with an optional trailing accessory, then content.
struct Card<Content: View, Accessory: View>: View {
    var title: String?
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title).font(.headline)
                    }
                    Spacer(minLength: Spacing.s)
                    accessory
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            content
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
    }
}

extension Card where Accessory == EmptyView {
    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = EmptyView()
        self.content = content()
    }
}

/// Label–value rows separated by hairlines, for compact facts inside a card.
struct FactRows: View {
    let rows: [(label: String, value: String, monospaced: Bool)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Divider() }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                    Text(row.label).foregroundStyle(.secondary)
                    Spacer(minLength: Spacing.m)
                    Text(row.value)
                        .font(row.monospaced ? .callout.monospaced() : .callout)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.vertical, Spacing.s)
            }
        }
    }
}

extension View {
    /// Main-window card surface.
    func cardBackground(cornerRadius: CGFloat = Radius.large) -> some View {
        background(Brand.cardFill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Brand.cardStroke))
    }

    /// Floating surface for the menu bar popover: Liquid Glass on macOS 26 and later,
    /// a quiet material card before that.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = Radius.large, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint?.opacity(0.18)), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill((tint ?? .primary).opacity(tint == nil ? 0.05 : 0.10))
            )
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Brand.cardStroke))
        }
    }
}
