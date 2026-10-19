# Orbit Orders (SwiftUI fixture)

An ordinary SwiftUI macOS app used to develop and test sharing native Mac apps. It has no
OpenTraffic code in it: whatever works for Orbit has to work for any other app.

## Build

```sh
sh Examples/macapp-orbit/package.sh
```

This builds the Swift package in debug and writes `Examples/macapp-orbit/dist/Orbit.app`
(bundle identifier `se.medda.orbit`, signed ad hoc). Needs Xcode or the Command Line Tools with
Swift 6 and macOS 14 or later. `swift run --package-path Examples/macapp-orbit` also starts it,
but without a bundle identifier.

The orders are fixed (30 of them, the same every launch), so screenshots and tests see the same
app each time. Nothing is saved: quitting resets everything.

Like any Mac app, Orbit reopens the windows it had open when it was last stopped. For a clean
start with only the main window, launch it with `-ApplePersistenceIgnoreState YES`:

```sh
Examples/macapp-orbit/dist/Orbit.app/Contents/MacOS/Orbit -ApplePersistenceIgnoreState YES
```

## What is where

Accessibility identifiers are in brackets.

| Control | Where | Notes |
| --- | --- | --- |
| Segmented filter All / Open / Shipped (`filter`) | Main window, sidebar | Also in Orders > Filter |
| Order list (`orderList`) | Main window, sidebar | A `List` with selection; 30 rows, scrolls in the default window size |
| Row context menu: Mark as Shipped/Open, Duplicate, Delete | Right-click a row | Accessibility exposes `AXShowMenu` on the row's texts, not on the row |
| New customer field (`newCustomer`), Add Order button (`addOrder`) | Main window, below the list | Return in the field adds too; Add Order has a tooltip |
| Express shipping toggle (`express`) | Main window, detail, Shipping box | |
| Quantity stepper (`quantity`) | Main window, detail, Shipping box | 1 to 20 |
| Note text field (`note`) | Main window, detail, Shipping box | |
| Door code secure field (`doorCode`) | Main window, detail, Shipping box | `AXSecureTextField` |
| Edit Address… button (`editAddress`) | Main window, detail | Opens a sheet |
| Address sheet: Street (`street`), City (`city`), Cancel (`cancelAddress`), Save (`saveAddress`) | Sheet on the main window | Escape cancels, Return saves |
| Tracking button (`tracking`) | Main window, detail | Opens a popover (`trackingPopover`); has a tooltip |
| Mark as Shipped / Mark as Open (`markShipped`) | Main window, detail | Prominent button with a tooltip |
| Delete Order (`deleteOrder`) | Main window, detail | Opens an alert with Cancel and Delete |
| Orders > Mark All Shipped (⇧⌘S) | Menu bar | The app's own menu |
| Orders > Show Statistics (⌥⌘I) | Menu bar | Opens the second window |
| Orders > Filter | Menu bar | A submenu with the three filters |
| Statistics (`statistics`) | Second window (a `WindowGroup`) | Counts and revenue, updates live |
