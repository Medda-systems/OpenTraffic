import AppKit
import OpenTrafficCore

/// Below Choose App…'s open panel: the Share ▾ choices of a listed Mac app, for the app being chosen.
/// Where it's shared (a temporary public URL or a lasting OpenTunnel address, whichever can be used)
/// and Share with Empty Data.
final class MacAppChoiceAccessory: NSView {
    private let address = NSPopUpButton(frame: .zero, pullsDown: false)
    private let emptyData = NSButton(checkboxWithTitle: "Share with Empty Data", target: nil, action: nil)

    init(kind: TunnelKind, canShare: Bool, canShareWithOpenTunnel: Bool) {
        super.init(frame: .zero)
        address.autoenablesItems = false
        for (title, itemKind, provider, enabled) in [
            ("Temporary Public URL", TunnelKind.quick, TunnelProvider.cloudflare, canShare),
            ("Lasting Address with OpenTunnel", .opentunnel, .opentunnel, canShareWithOpenTunnel),
        ] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = itemKind.rawValue
            item.isEnabled = enabled
            item.image = BrandAssets.logo(provider, style: .menu)
            address.menu?.addItem(item)
        }
        // The default kind when it can be used, else the one that can.
        let usable = address.itemArray.filter(\.isEnabled)
        let preferred = usable.first { $0.representedObject as? String == kind.rawValue } ?? usable.first ?? address.itemArray.first
        address.select(preferred)
        address.setAccessibilityLabel("Share at")
        emptyData.toolTip = "Viewers start the app with no data instead of a copy of yours."

        let label = NSTextField(labelWithString: "Share at:")
        let row = NSStackView(views: [label, address])
        row.spacing = 8
        let stack = NSStackView(views: [row, emptyData])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setFrameSize(stack.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Where the chosen app is shared.
    var kind: TunnelKind {
        (address.selectedItem?.representedObject as? String).flatMap(TunnelKind.init(rawValue:)) ?? .quick
    }

    /// The data the copy starts with.
    var data: MacAppSession.DataSource { emptyData.state == .on ? .empty : .copy }
}
