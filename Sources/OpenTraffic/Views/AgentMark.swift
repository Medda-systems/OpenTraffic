import SwiftUI
import OpenTrafficCore

/// A coding agent's mark, in its colour: Claude, Codex, Cursor, OpenCode; a sparkle for the rest.
struct AgentMark: View {
    let name: String
    var size: CGFloat = 14
    /// Overrides the agent's colour (white on an avatar, for example).
    var color: Color?

    var body: some View {
        Group {
            if let brand = AgentBrand(agentName: name), let image = BrandAssets.agentMark(brand) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.9))
                    .frame(width: size, height: size)
            }
        }
        .foregroundStyle(color ?? Self.color(for: name))
        .accessibilityLabel(name)
    }

    /// The agent's colour: its brand's when that works on any background, else OpenTraffic's agent purple.
    static func color(for name: String) -> Color {
        Color(hex: AgentBrand(agentName: name)?.color ?? CollabRoom.agentColor) ?? .purple
    }
}

/// An agent in a list of people: its mark on its colour, where a person has their initials.
struct AgentAvatar: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        AgentMark(name: name, size: size * 0.55, color: .white)
            .frame(width: size, height: size)
            .background(AgentMark.color(for: name), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A native segmented control whose segments show an image and a title side by side, which SwiftUI's
/// segmented picker on macOS doesn't (it drops the image).
struct IconSegmentedControl<Value: Hashable>: NSViewRepresentable {
    struct Segment {
        let value: Value
        let title: String
        let image: NSImage?
    }

    let segments: [Segment]
    @Binding var selection: Value

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.segmentCount = segments.count
        for (index, segment) in segments.enumerated() {
            control.setLabel(segment.title, forSegment: index)
            control.setImage(segment.image, forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
        }
        control.selectedSegment = segments.firstIndex { $0.value == selection } ?? -1
        control.setAccessibilityLabel("App")
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: IconSegmentedControl

        init(_ parent: IconSegmentedControl) { self.parent = parent }

        @objc func changed(_ control: NSSegmentedControl) {
            guard parent.segments.indices.contains(control.selectedSegment) else { return }
            parent.selection = parent.segments[control.selectedSegment].value
        }
    }
}
