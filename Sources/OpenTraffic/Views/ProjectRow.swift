import SwiftUI
import OpenTrafficCore

/// A project: its tunnels' combined state, with Start All / Stop All.
struct ProjectRow: View {
    @Bindable var store: AppStore
    let name: String

    var body: some View {
        let tunnels = store.tunnels(inProject: name)
        let running = tunnels.filter { store.isActive($0.id) }.count
        HStack(spacing: Spacing.s) {
            Image(systemName: running == 0 ? "folder" : "folder.fill")
                .foregroundStyle(running == 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).fontWeight(.medium).lineLimit(1)
                Text(running == 0 ? "\(tunnels.count) tunnel\(tunnels.count == 1 ? "" : "s")" : "\(running) of \(tunnels.count) running")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Spacing.xs)
            if running < tunnels.count {
                RowIconButton(title: "Start All", systemImage: "play.fill") { store.startProject(name) }
            }
            if running > 0 {
                RowIconButton(title: "Stop All", systemImage: "stop.fill") { store.stopProject(name) }
            }
        }
        .contextMenu {
            Group {
                Button("Start All", systemImage: "play.fill") { store.startProject(name) }
                    .disabled(running == tunnels.count)
                Button("Stop All", systemImage: "stop.fill") { store.stopProject(name) }
                    .disabled(running == 0)
            }
            .untintedMenuItems()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project \(name), \(running) of \(tunnels.count) running")
    }
}
