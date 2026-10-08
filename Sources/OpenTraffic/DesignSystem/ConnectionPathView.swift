import SwiftUI
import OpenTrafficCore

/// One fix the user can apply directly from a failed or skipped check.
struct HealthFix: Identifiable {
    let title: String
    var isProminent = false
    let action: () -> Void
    var id: String { title }
}

/// The path traffic takes — local service → this Mac → Cloudflare → public hostname —
/// with each stop lit by its health check and traffic animating along healthy links.
struct ConnectionPathView: View {
    let stages: [ConnectionStage]
    var provider: TunnelProvider = .cloudflare
    var localOrigin: String?
    /// 0…1, how busy the tunnel has been recently. Drives the link animation.
    var activity: Double = 0
    let fixes: (TunnelHealthCheck) -> [HealthFix]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                StageNode(stage: stage, provider: provider, localOrigin: localOrigin, fixes: fixes)
                if index < stages.count - 1 {
                    PathLink(
                        flowing: ConnectionPath.isLinkFlowing(from: stage, to: stages[index + 1]),
                        broken: stage.state == .failed || stages[index + 1].state == .failed,
                        activity: activity
                    )
                    .frame(height: StageNode.diameter)
                    .frame(minWidth: 24, maxWidth: .infinity)
                }
            }
        }
        .animation(.spring(duration: 0.45), value: stages)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection path")
    }
}

private struct StageNode: View {
    static let diameter: CGFloat = 46

    let stage: ConnectionStage
    let provider: TunnelProvider
    let localOrigin: String?
    let fixes: (TunnelHealthCheck) -> [HealthFix]
    @State private var showingDetail = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsActive) private var animationsActive

    var body: some View {
        Button {
            showingDetail = true
        } label: {
            VStack(spacing: Spacing.s - 2) {
                ZStack {
                    if stage.state == .failed && !reduceMotion && animationsActive {
                        PulseRing(color: tint, lineWidth: 2, scale: 1.35, startOpacity: 0.7, duration: 1.4)
                    }
                    Circle().fill(tint.opacity(stage.state == .skipped ? 0.06 : 0.14))
                    Circle().strokeBorder(tint.opacity(stage.state == .skipped ? 0.35 : 0.9), lineWidth: 1.5)
                    icon
                }
                .frame(width: Self.diameter, height: Self.diameter)
                .overlay(alignment: .bottomTrailing) { badge }

                VStack(spacing: 1) {
                    Text(stage.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(stateLabel)
                        .font(.caption2)
                        .foregroundStyle(stage.state == .failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .contentTransition(.opacity)
                }
                .frame(width: 112)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(stage.detail ?? stage.title)
        .popover(isPresented: $showingDetail, arrowEdge: .bottom) { detail }
        .accessibilityLabel("\(stage.title), \(stateLabel)")
        .accessibilityHint(stage.detail ?? "")
    }

    @ViewBuilder
    private var icon: some View {
        if stage.kind == .localService, let localOrigin {
            TunnelIcon(originURL: localOrigin, fallbackSymbol: symbol, size: 30)
        } else if stage.kind == .edge {
            ProviderLogo(provider: provider, height: 18, tint: stage.state == .skipped ? .secondary : tint)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(stage.state == .skipped ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch stage.state {
        case .ok, .failed:
            Image(systemName: stage.state == .ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
                .font(.system(size: 15, weight: .bold))
                .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1.5))
                .offset(x: 3, y: 3)
                .transition(.scale.combined(with: .opacity))
        case .working:
            ProgressView().controlSize(.mini).offset(x: 3, y: 3)
        case .skipped:
            EmptyView()
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(stage.title).font(.headline)
                Spacer()
                Text(stateLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, Spacing.s - 2)
                    .padding(.vertical, 2)
                    .background(tint.opacity(0.14), in: Capsule())
            }
            Text(stage.detail ?? "No details yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let check = stage.sourceCheck {
                let fixes = fixes(check)
                if !fixes.isEmpty {
                    HStack {
                        ForEach(fixes) { fix in
                            if fix.isProminent {
                                Button(fix.title) { showingDetail = false; fix.action() }
                                    .buttonStyle(.borderedProminent)
                            } else {
                                Button(fix.title) { showingDetail = false; fix.action() }
                            }
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(Spacing.l)
        .frame(width: 300)
    }

    private var symbol: String {
        switch stage.kind {
        case .localService: "chevron.left.forwardslash.chevron.right"
        case .connector: "laptopcomputer"
        case .edge: "cloud.fill"
        case .publicSite: "globe"
        }
    }

    private var tint: Color {
        switch stage.state {
        case .ok: .green
        case .failed: .red
        case .working: .blue
        case .skipped: .secondary
        }
    }

    private var stateLabel: String {
        switch (stage.kind, stage.state) {
        case (_, .working): "Checking…"
        case (_, .skipped): "Not checked"
        case (.localService, .ok): "Responding"
        case (.localService, .failed): "Not responding"
        case (.connector, .ok): "Connected"
        case (.connector, .failed): "Failed"
        case (.edge, .ok): "Healthy"
        case (.edge, .failed): "Down"
        case (.publicSite, .ok): "Reachable"
        case (.publicSite, .failed): "Unreachable"
        }
    }
}

/// A link between two stages. Flowing links carry animated packets; broken ones are dashed red.
private struct PathLink: View {
    let flowing: Bool
    let broken: Bool
    let activity: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.animationsActive) private var animationsActive

    private static let inset: CGFloat = 6
    /// Idle links show one slow heartbeat packet; real traffic gets more, faster packets.
    private var packetCount: Int { activity > 0 ? 2 + Int((activity * 4).rounded()) : 1 }
    private var period: Double { 1 / (activity > 0 ? 0.35 + activity * 0.65 : 0.25) }

    var body: some View {
        Canvas { context, size in
            let inset = Self.inset
            let y = size.height / 2
            var line = Path()
            line.move(to: CGPoint(x: inset, y: y))
            line.addLine(to: CGPoint(x: size.width - inset, y: y))

            if flowing {
                context.stroke(line, with: .color(.green.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                if reduceMotion {
                    // Still packets in place of the moving ones.
                    for index in 0..<packetCount {
                        let phase = Double(index) / Double(packetCount)
                        let x = inset + (size.width - inset * 2) * phase
                        let edgeFade = min(phase, 1 - phase) * 6
                        let rect = CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)
                        context.fill(Path(ellipseIn: rect), with: .color(.green.opacity(min(1, max(0.4, edgeFade)))))
                    }
                }
            } else {
                let color: Color = broken ? .red.opacity(0.55) : .secondary.opacity(0.35)
                context.stroke(line, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))
            }

            // Direction chevron at the receiving end.
            var arrow = Path()
            let tip = CGPoint(x: size.width - inset, y: y)
            arrow.move(to: CGPoint(x: tip.x - 4, y: y - 3.5))
            arrow.addLine(to: tip)
            arrow.addLine(to: CGPoint(x: tip.x - 4, y: y + 3.5))
            let arrowColor: Color = flowing ? .green.opacity(0.6) : (broken ? .red.opacity(0.55) : .secondary.opacity(0.4))
            context.stroke(arrow, with: .color(arrowColor), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .overlay {
            if flowing && !reduceMotion && animationsActive {
                PacketStream(count: packetCount, period: period, inset: Self.inset)
            }
        }
        .accessibilityHidden(true)
    }
}
