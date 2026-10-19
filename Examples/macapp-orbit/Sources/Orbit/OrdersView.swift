import SwiftUI

/// The main window: the order list on the left, the selected order on the right.
struct OrdersView: View {
    @Bindable var store: OrderStore

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 330)
                .background(.quaternary.opacity(0.35))
            Divider()
            Group {
                if let index = store.index(of: store.selectedID) {
                    OrderDetail(store: store, index: index)
                } else {
                    Text("No order selected").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 480, idealHeight: 540)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Orbit Orders").font(.title2.bold())
                Spacer()
                Text("\(store.openCount) open").font(.callout).foregroundStyle(.secondary)
            }
            Picker("Filter", selection: $store.filter) {
                ForEach(OrderFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("filter")

            List(selection: $store.selectedID) {
                ForEach(store.visible) { order in
                    OrderRow(order: order)
                        .tag(order.id)
                        .contextMenu {
                            Button(order.shipped ? "Mark as Open" : "Mark as Shipped") { store.toggleShipped(order.id) }
                            Button("Duplicate") { store.duplicate(order.id) }
                            Divider()
                            Button("Delete", role: .destructive) { store.delete(order.id) }
                        }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("orderList")

            HStack {
                TextField("New customer", text: $store.newCustomer)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.add() }
                    .accessibilityIdentifier("newCustomer")
                Button("Add Order") { store.add() }
                    .disabled(store.newCustomer.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add an order for the customer typed on the left")
                    .accessibilityIdentifier("addOrder")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }
}

struct OrderRow: View {
    let order: Order

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(order.shipped ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(order.customer).font(.body.weight(.medium))
                Text("\(order.number) · \(order.quantity) item\(order.quantity == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(order.amount, format: .currency(code: "USD")).monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

struct OrderDetail: View {
    @Bindable var store: OrderStore
    let index: Int
    @State private var editingAddress = false
    @State private var confirmingDelete = false
    @State private var showingTracking = false

    var body: some View {
        let order = store.orders[index]
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(order.customer).font(.largeTitle.bold())
                Text("Order \(order.number) · \(order.shipped ? "Shipped" : "Open")")
                    .foregroundStyle(order.shipped ? .green : .orange)
            }
            GroupBox("Shipping") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Express shipping", isOn: $store.orders[index].express)
                        .accessibilityIdentifier("express")
                    Stepper("Quantity: \(order.quantity)", value: $store.orders[index].quantity, in: 1...20)
                        .accessibilityIdentifier("quantity")
                    HStack {
                        Text("Note")
                        TextField("Add a note for the warehouse", text: $store.orders[index].note)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("note")
                    }
                    HStack {
                        Text("Door code")
                        SecureField("Optional", text: $store.orders[index].doorCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .accessibilityIdentifier("doorCode")
                        Spacer()
                        Button("Edit Address…") { editingAddress = true }
                            .accessibilityIdentifier("editAddress")
                        Button {
                            showingTracking = true
                        } label: {
                            Label("Tracking", systemImage: "shippingbox")
                        }
                        .help("Show the tracking number")
                        .accessibilityIdentifier("tracking")
                        .popover(isPresented: $showingTracking, arrowEdge: .bottom) {
                            TrackingPopover(order: order)
                        }
                    }
                }
                .padding(8)
            }
            HStack {
                Text("Total").font(.title3)
                Spacer()
                Text(order.total, format: .currency(code: "USD")).font(.title3.bold()).monospacedDigit()
            }
            HStack {
                Button(order.shipped ? "Mark as Open" : "Mark as Shipped") { store.toggleShipped(order.id) }
                    .buttonStyle(.borderedProminent)
                    .help(order.shipped ? "Move this order back to Open" : "Mark this order as shipped")
                    .accessibilityIdentifier("markShipped")
                Button("Delete Order", role: .destructive) { confirmingDelete = true }
                    .accessibilityIdentifier("deleteOrder")
            }
            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .sheet(isPresented: $editingAddress) {
            AddressSheet(order: $store.orders[index])
        }
        .alert("Delete the order for \(order.customer)?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { store.delete(order.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Order \(order.number) will be removed. This cannot be undone.")
        }
    }
}

struct TrackingPopover: View {
    let order: Order

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tracking").font(.headline)
            Text(order.trackingNumber).font(.body.monospaced()).textSelection(.enabled)
            Text(order.express ? "Express, 1 to 2 days" : "Standard, 3 to 5 days")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 220, alignment: .leading)
        .accessibilityIdentifier("trackingPopover")
    }
}

struct AddressSheet: View {
    @Binding var order: Order
    @Environment(\.dismiss) private var dismiss
    @State private var street = ""
    @State private var city = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Shipping address for \(order.customer)").font(.headline)
            Form {
                TextField("Street", text: $street).accessibilityIdentifier("street")
                TextField("City", text: $city).accessibilityIdentifier("city")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("cancelAddress")
                Button("Save") {
                    order.street = street
                    order.city = city
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("saveAddress")
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            street = order.street
            city = order.city
        }
    }
}
