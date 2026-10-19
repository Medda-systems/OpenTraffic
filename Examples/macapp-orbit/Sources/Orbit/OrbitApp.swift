import SwiftUI

@main
struct OrbitApp: App {
    @State private var store = OrderStore()

    var body: some Scene {
        WindowGroup("Orbit Orders", id: "orders") {
            OrdersView(store: store)
        }
        .defaultSize(width: 860, height: 540)
        .commands { OrdersCommands(store: store) }

        // The second window, opened from Orders > Show Statistics.
        WindowGroup("Statistics", id: "statistics") {
            StatisticsView(store: store)
        }
        .defaultSize(width: 360, height: 260)
    }
}

/// The app's own menu, between View and Window.
struct OrdersCommands: Commands {
    let store: OrderStore
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Orders") {
            Button("Mark All Shipped") { store.markAllShipped() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Show Statistics") { openWindow(id: "statistics") }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Divider()
            Picker("Filter", selection: Binding(get: { store.filter }, set: { store.filter = $0 })) {
                ForEach(OrderFilter.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }
}

struct StatisticsView: View {
    let store: OrderStore

    var body: some View {
        Form {
            LabeledContent("Orders", value: "\(store.orders.count)")
            LabeledContent("Open", value: "\(store.openCount)")
            LabeledContent("Shipped", value: "\(store.orders.count - store.openCount)")
            LabeledContent("Express", value: "\(store.orders.filter(\.express).count)")
            LabeledContent("Revenue") {
                Text(store.revenue, format: .currency(code: "USD")).monospacedDigit()
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 300, minHeight: 220)
        .accessibilityIdentifier("statistics")
    }
}
