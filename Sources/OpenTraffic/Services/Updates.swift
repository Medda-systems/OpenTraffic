import Foundation
import Sparkle
import SwiftUI

/// Automatic updates through Sparkle. The feed (`SUFeedURL`) is the public OpenTraffic-releases repo,
/// and every update must carry an EdDSA signature matching `SUPublicEDKey`; both are in Info.plist.
@MainActor
enum Updates {
    /// Release builds with an update key. Debug builds never offer to replace themselves.
    static let isAvailable: Bool = {
        #if DEBUG
        false
        #else
        Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil
        #endif
    }()

    static let controller = SPUStandardUpdaterController(startingUpdater: isAvailable, updaterDelegate: nil, userDriverDelegate: nil)

    static var updater: SPUUpdater { controller.updater }

    static func start() {
        _ = controller
    }

    static func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Settings → General: how OpenTraffic keeps itself up to date.
struct UpdatesSettingsSection: View {
    @State private var checksAutomatically = Updates.updater.automaticallyChecksForUpdates
    @State private var installsAutomatically = Updates.updater.automaticallyDownloadsUpdates

    var body: some View {
        Section {
            Toggle("Check for updates automatically", isOn: $checksAutomatically)
                .onChange(of: checksAutomatically) { Updates.updater.automaticallyChecksForUpdates = checksAutomatically }
            Toggle("Download and install updates in the background", isOn: $installsAutomatically)
                .onChange(of: installsAutomatically) { Updates.updater.automaticallyDownloadsUpdates = installsAutomatically }
                .disabled(!checksAutomatically)
            LabeledContent("Version \(version)") {
                Button("Check Now", action: Updates.checkForUpdates)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(Updates.isAvailable
                 ? "OpenTraffic checks github.com once a day. Updates are verified with Medda Systems' signing key before they're installed."
                 : "This build doesn't update itself.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .disabled(!Updates.isAvailable)
    }

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(short) (\(build))"
    }
}
