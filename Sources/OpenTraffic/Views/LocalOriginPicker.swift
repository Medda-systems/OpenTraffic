import SwiftUI
import OpenTrafficCore

/// Choose a local web server detected on this Mac, one already used by a tunnel, or type a URL.
/// Renders Form sections, so place it inside a Form.
struct LocalOriginPicker: View {
    @Bindable var store: AppStore
    @Binding var selectionID: String
    @Binding var localURL: String
    var validationMessage: InlineValidation?
    let onPickOption: (LocalOriginOption) -> Void

    struct InlineValidation {
        let severity: Severity
        let message: String
        var isChecking = false
    }

    var body: some View {
        Section {
            if sections.isEmpty {
                Text(store.isScanningLocalServices
                     ? "Looking for web servers on this Mac…"
                     : "No web servers found. Start your dev server and rescan, or enter a URL below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sections.detected) { option in optionRow(option) }
            if !sections.saved.isEmpty {
                ForEach(sections.saved) { option in optionRow(option) }
            }
            TextField("URL", text: $localURL, prompt: Text("http://localhost:3000"))
                .onChange(of: localURL) {
                    if let selected = store.localOriginOptions.first(where: { $0.id == selectionID }),
                       selected.url != localURL {
                        selectionID = "manual"
                    }
                }
            if let validationMessage {
                HStack(spacing: Spacing.s) {
                    if validationMessage.isChecking {
                        ProgressView().controlSize(.mini)
                        Text(validationMessage.message).font(.callout).foregroundStyle(.secondary)
                    } else {
                        InlineMessage(severity: validationMessage.severity, message: validationMessage.message)
                    }
                }
            }
        } header: {
            HStack {
                Text(Vocabulary.localService)
                Spacer()
                if store.isScanningLocalServices {
                    ProgressView().controlSize(.mini)
                }
                Button("Rescan", systemImage: "arrow.clockwise") {
                    Task { await store.scanLocalServices() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(store.isScanningLocalServices)
                .help("Scan this Mac for web servers")
            }
        }
    }

    private var sections: LocalOriginResolver.OriginSections { store.localOriginSections }

    private func optionRow(_ option: LocalOriginOption) -> some View {
        let detected = detectedService(for: option)
        let selected = selectionID == option.id
        return Button {
            selectionID = option.id
            localURL = option.url
            onPickOption(option)
        } label: {
            HStack(spacing: Spacing.m) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .font(.body)
                // The site's favicon, as in the menu bar's Localhost list.
                TunnelIcon(originURL: option.url, fallbackSymbol: "server.rack", size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.name).lineLimit(1)
                    Text(subtitle(for: option, detected: detected))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: Spacing.xs)
                Text(detected != nil ? "Running" : "Saved")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(detected != nil ? .green : .secondary)
                    .padding(.horizontal, Spacing.s - 2)
                    .padding(.vertical, 1)
                    .background((detected != nil ? Color.green : Color.secondary).opacity(0.12), in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(option.url)
    }

    private func detectedService(for option: LocalOriginOption) -> DiscoveredLocalService? {
        guard option.id.hasPrefix("detected:"),
              let port = Int(option.id.dropFirst("detected:".count)) else { return nil }
        return store.detectedLocalServices.first(where: { $0.port == port })
    }

    private func subtitle(for option: LocalOriginOption, detected: DiscoveredLocalService?) -> String {
        guard let detected else { return option.url }
        var parts: [String] = ["localhost:\(detected.port)"]
        if let process = detected.processName?.nilIfBlank { parts.insert(process, at: 0) }
        if let code = detected.statusCode { parts.append("HTTP \(code)") }
        if let upSince = detected.upSince ?? detected.startedAt {
            parts.append(ShareableServiceUptime.text(since: upSince))
        }
        return parts.joined(separator: " · ")
    }
}

/// "up 12 min": how long a local server has been answering without interruption.
enum ShareableServiceUptime {
    static func text(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        guard seconds >= 60 else { return "just up" }
        return "up " + (formatter.string(from: seconds) ?? "")
    }

    private static let formatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.maximumUnitCount = 1
        formatter.allowedUnits = [.minute, .hour, .day]
        return formatter
    }()
}
