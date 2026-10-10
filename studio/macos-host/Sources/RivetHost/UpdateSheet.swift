import SwiftUI

/// The update sheet: reports every outcome of a check and drives the
/// download → in-place swap. States mirror AppModel.UpdatePhase; the layout
/// follows the taskly update sheet in compact form (no i18n layer yet —
/// Studio ships English-only UI).
struct UpdateSheet: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch model.updatePhase {
            case .idle:
                Text("Checking for updates…")
                    .font(.headline)

            case .checking:
                ProgressView()
                Text("Checking for updates…")
                    .font(.headline)

            case .upToDate:
                Text("You're up to date.")
                    .font(.headline)
                Text("BenchPilot Studio is on the latest release.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

            case .available:
                Text("BenchPilot Studio \(model.updateAvailableVersion ?? "") is available")
                    .font(.headline)
                Text("The new version downloads, verifies its Ed25519 signature and checksum, and swaps the app in place. The app relaunches when done.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Download and Install") { model.installUpdate() }
                        .keyboardShortcut(.defaultAction)
                    Button("Later") { model.dismissUpdateSheet() }
                }

            case .downloading:
                Text("Downloading BenchPilot Studio…")
                    .font(.headline)
                ProgressView(value: Double(model.updateProgressPercent), total: 100)
                Text("\(model.updateProgressPercent)%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

            case .failed:
                Text("Update failed")
                    .font(.headline)
                Text(model.updateErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Button("Try Again") { model.checkForUpdates() }
                    Button("Close") { model.dismissUpdateSheet() }
                }

            case .notInstalled:
                Text("This copy can't self-update")
                    .font(.headline)
                Text("Only a copy in /Applications updates in place. Download the latest release and drag it to Applications.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Open Releases Page") { model.openReleasesPage() }
                    Button("Close") { model.dismissUpdateSheet() }
                }
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
