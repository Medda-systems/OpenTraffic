import SwiftUI

/// Starts the app, or, with an edit on the command line, changes the saved orders without opening a
/// window and quits (for tests that need the app to have saved something of its own):
///
///     Orbit --set-note <order id> <text>    the order's note
///     Orbit --add-order <customer>          a new order, selected
@main
enum Launcher {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let edit = arguments.first, edit == "--set-note" || edit == "--add-order" else {
            OrbitApp.main()
            return
        }
        MainActor.assumeIsolated {
            let store = OrderStore()
            switch (edit, arguments.count) {
            case ("--set-note", 3):
                guard let id = Int(arguments[1]), let index = store.index(of: id) else { fail("no order \(arguments[1])") }
                store.orders[index].note = arguments[2]
            case ("--add-order", 2):
                store.newCustomer = arguments[1]
                store.add()
            default:
                fail("usage: Orbit --set-note <order id> <text> | --add-order <customer>")
            }
            print("Saved \(store.orders.count) orders to \(OrderStore.file.path)")
        }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Orbit: \(message)\n".utf8))
        exit(2)
    }
}

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
        // For tests of what the app may touch: the selected order's note names the file.
        CommandGroup(after: .newItem) {
            Button("Open File Named in Note") { store.openFileNamedInNote() }
            Button("Save Orders to File Named in Note") { store.saveOrdersToFileNamedInNote() }
        }
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
