import Foundation
import Observation

struct Order: Identifiable, Equatable {
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

enum OrderFilter: String, CaseIterable, Identifiable {
    case all = "All", open = "Open", shipped = "Shipped"
    var id: String { rawValue }
}

/// The app's whole state, shared by the main window, the Statistics window and the Orders menu.
@MainActor @Observable final class OrderStore {
    var orders: [Order]
    var selectedID: Int? = 1
    var filter: OrderFilter = .all
    var newCustomer = ""

    init() {
        // Enough orders that the list has to scroll in the default window size. Fixed values, so
        // screenshots and tests see the same app every launch.
        let names = [
            "Edward", "Alan Turing", "Grace Hopper", "Linus Torvalds", "Ada Lovelace", "Margaret Hamilton",
            "Dennis Ritchie", "Barbara Liskov", "Ken Thompson", "Radia Perlman", "Donald Knuth", "Frances Allen",
            "John McCarthy", "Hedy Lamarr", "Tim Berners-Lee", "Katherine Johnson", "Edsger Dijkstra",
            "Annie Easley", "Guido van Rossum", "Sophie Wilson", "Bjarne Stroustrup", "Joan Clarke",
            "Niklaus Wirth", "Mary Kenneth Keller", "Leslie Lamport", "Adele Goldberg", "Vint Cerf",
            "Jean Sammet", "Tony Hoare", "Evelyn Berezin",
        ]
        orders = names.enumerated().map { offset, name in
            let id = offset + 1
            return Order(id: id, customer: name, amount: Double(20 + (id * 37) % 280) + (id % 2 == 0 ? 0.5 : 0),
                         shipped: id % 3 == 0, express: id % 4 == 1, quantity: 1 + id % 3)
        }
        orders[0].note = "Gift wrap"
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
}
