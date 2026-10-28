import Foundation
import Observation

struct Order: Identifiable, Equatable, Codable {
    let id: Int
    var customer: String
    var amount: Double
    var shipped = false
    var express = false
    var quantity = 1
    var note = ""
    var doorCode = ""
    var street = ""
    var city = ""

    var number: String { "#\(1000 + id)" }
    var total: Double { amount * Double(quantity) + (express ? 15 : 0) }
    var trackingNumber: String { shipped ? "1Z ORB \(String(format: "%06d", id * 7919 % 1_000_000))" : "Not shipped yet" }
}

enum OrderFilter: String, CaseIterable, Identifiable, Codable {
    case all = "All", open = "Open", shipped = "Shipped"
    var id: String { rawValue }
}

/// The app's whole state, shared by the main window, the Statistics window and the Orders menu.
///
/// Saved as JSON in Application Support/se.medda.orbit/orders.json after every change and loaded at
/// launch, like an ordinary app keeps its documents. Without that file (a first launch) it starts with
/// the fixed sample orders.
@MainActor @Observable final class OrderStore {
    var orders: [Order] { didSet { save() } }
    var selectedID: Int? = 1 { didSet { save() } }
    var filter: OrderFilter = .all { didSet { save() } }
    var newCustomer = ""

    /// What is saved.
    struct Saved: Codable {
        var orders: [Order]
        var selectedID: Int?
        var filter: OrderFilter
    }

    /// Application Support/se.medda.orbit/orders.json in the user's home (`CFFIXED_USER_HOME` when set).
    /// A fixed folder name: the Electron Orbit fixture already uses Application Support/Orbit.
    nonisolated static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("se.medda.orbit", isDirectory: true)
            .appendingPathComponent("orders.json")
    }

    @ObservationIgnored private var loading = true

    init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            orders = saved.orders
            selectedID = saved.selectedID
            filter = saved.filter
        } else {
            orders = Self.sampleOrders
        }
        loading = false
    }

    /// Enough orders that the list has to scroll in the default window size. Fixed values, so
    /// screenshots and tests see the same app on every first launch.
    static var sampleOrders: [Order] {
        let names = [
            "Edward", "Alan Turing", "Grace Hopper", "Linus Torvalds", "Ada Lovelace", "Margaret Hamilton",
            "Dennis Ritchie", "Barbara Liskov", "Ken Thompson", "Radia Perlman", "Donald Knuth", "Frances Allen",
            "John McCarthy", "Hedy Lamarr", "Tim Berners-Lee", "Katherine Johnson", "Edsger Dijkstra",
            "Annie Easley", "Guido van Rossum", "Sophie Wilson", "Bjarne Stroustrup", "Joan Clarke",
            "Niklaus Wirth", "Mary Kenneth Keller", "Leslie Lamport", "Adele Goldberg", "Vint Cerf",
            "Jean Sammet", "Tony Hoare", "Evelyn Berezin",
        ]
        var orders = names.enumerated().map { offset, name in
            let id = offset + 1
            return Order(id: id, customer: name, amount: Double(20 + (id * 37) % 280) + (id % 2 == 0 ? 0.5 : 0),
                         shipped: id % 3 == 0, express: id % 4 == 1, quantity: 1 + id % 3)
        }
        orders[0].note = "Gift wrap"
        return orders
    }

    /// Writes the orders, the selection and the filter (atomically, so a quit never leaves half a file).
    func save() {
        guard !loading else { return }
        let file = Self.file
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Saved(orders: orders, selectedID: selectedID, filter: filter)).write(to: file, options: .atomic)
        } catch {
            print("Orbit couldn't save its orders to \(file.path): \(error.localizedDescription)")
        }
    }

    var visible: [Order] {
        switch filter {
        case .all: orders
        case .open: orders.filter { !$0.shipped }
        case .shipped: orders.filter(\.shipped)
        }
    }

    var openCount: Int { orders.filter { !$0.shipped }.count }
    var revenue: Double { orders.reduce(0) { $0 + $1.total } }

    func index(of id: Int?) -> Int? { orders.firstIndex { $0.id == id } }

    func add() {
        let name = newCustomer.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let id = (orders.map(\.id).max() ?? 0) + 1
        orders.append(Order(id: id, customer: name, amount: Double(20 + (id * 37) % 280)))
        if filter == .shipped { filter = .all }
        selectedID = id
        newCustomer = ""
    }

    func toggleShipped(_ id: Int) {
        guard let index = index(of: id) else { return }
        orders[index].shipped.toggle()
    }

    func duplicate(_ id: Int) {
        guard let index = index(of: id) else { return }
        let source = orders[index]
        let copy = Order(id: (orders.map(\.id).max() ?? 0) + 1, customer: source.customer, amount: source.amount,
                         express: source.express, quantity: source.quantity, note: source.note)
        orders.insert(copy, at: index + 1)
        selectedID = copy.id
    }

    func delete(_ id: Int) {
        guard let index = index(of: id) else { return }
        orders.remove(at: index)
        if selectedID == id { selectedID = visible.first?.id }
    }

    func markAllShipped() {
        for index in orders.indices { orders[index].shipped = true }
    }

    /// File > Open File Named in Note: reads the file whose path is the selected order's note, as any app
    /// reads a file a person asks for, and puts its text in the note, or why it couldn't
    /// (`Couldn't open <path>: …`). Tests use it to try a file outside the app's sandbox.
    func openFileNamedInNote() {
        guard let index = index(of: selectedID) else { return }
        let path = orders[index].note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            orders[index].note = "Opened: " + (try String(contentsOfFile: path, encoding: .utf8))
        } catch {
            orders[index].note = "Couldn't open \(path): \(Self.reason(error))"
        }
    }

    /// File > Save Orders to File Named in Note: writes the orders as JSON over the file whose path is
    /// the selected order's note, and says in the note how it went (`Saved to <path>`,
    /// `Couldn't save <path>: …`).
    func saveOrdersToFileNamedInNote() {
        guard let index = index(of: selectedID) else { return }
        let path = orders[index].note.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try JSONEncoder().encode(orders).write(to: URL(fileURLWithPath: path))
            orders[index].note = "Saved to \(path)"
        } catch {
            orders[index].note = "Couldn't save \(path): \(Self.reason(error))"
        }
    }

    /// The system's reason (`Operation not permitted`), not Foundation's sentence around it.
    private static func reason(_ error: Error) -> String {
        let error = error as NSError
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(underlying.code)) {
            return String(cString: strerror(code.rawValue))
        }
        return error.localizedDescription
    }
}
