import SwiftUI
import RivetEmbedding
import RivetRuntime
import RivetSystem

@main
struct RivetHostApp: App {
    @StateObject private var model = AppModel()
    private let activationRouter = RivetActivationRouter()

    var body: some Scene {
        WindowGroup(RivetGeneratedConfig.displayName) {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 540)
                .task { model.start() }
                .sheet(isPresented: $model.updateSheetVisible) {
                    UpdateSheet(model: model)
                }
                // URL schemes and file associations are declared from
                // rivet.rktd during packaging. Keep activation handling in the
                // native UI layer; forward only application-level data to the
                // Racket backend when the app actually needs it.
                .onOpenURL { url in activationRouter.handle([url]) }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { model.checkForUpdates() }
                    .keyboardShortcut("u", modifiers: [.command])
            }
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var ready = false
    @Published var statusText = "Starting embedded Racket CS…"
    @Published var runtime: RuntimeStatus?
    @Published var operations: [OperationSummary] = []
    @Published var observations: [ObservationSummary] = []
    @Published var history: [OperationHistoryItem] = []
    @Published var busy = false
    @Published var serialLog: [String] = []
    @Published var udsPositive: Bool?
    @Published var udsResponseHex: String?
    @Published var udsNrc: String?
    @Published var doipVehicles: [DoipVehicle] = []
    @Published var dtcs: [DtcEntry] = []
    @Published var dtcAvailableMask: String?
    @Published var dtcMessage: String?
    @Published var evidence: OperationEvidence?
    @Published var flashSteps: [FlashStep] = []
    @Published var flashResultLine: String?

    private var backend: EmbeddedRacketBackend?
    // Not @Published: the service identity never changes, only the update
    // phase below does.
    private lazy var updateService = UpdateService()

    func start() {
        guard backend == nil else { return }

        do {
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend
            // Family startup pattern (taskly): boot the embedded runtime
            // synchronously on the main thread, then keep going in a
            // structured Task. The Task.detached + MainActor.run hop that
            // used to live here captures the non-Sendable model across
            // executors and fails Swift 6.1 sendability on the Intel runner.
            try backend.start()
            ready = true
            statusText = "Ready"
            autoCheckForUpdates()
        } catch {
            ready = false
            statusText = "Backend error: \(error)"
        }
    }

    private func api() -> RivetAPI? {
        guard let backend else { return nil }
        return RivetAPI(client: backend.client)
    }

    func refresh() async {
        guard ready, let api = api() else { return }
        do {
            let status = try await api.status()
            let active = try await api.list_operations()
            let activeObs = try await api.list_observations()
            let past = try await api.operation_history(limit: 25)
            runtime = status
            operations = active
            observations = activeObs
            history = past
            statusText = "Connected"
        } catch {
            runtime = nil
            operations = []
            observations = []
            history = []
            statusText = "\(error)"
        }
    }

    private func perform(_ label: String, _ body: @escaping (RivetAPI) async throws -> Void) {
        guard ready, let api = api(), !busy else { return }
        busy = true
        statusText = label
        Task {
            do {
                try await body(api)
                statusText = "Done"
            } catch {
                statusText = "Error: \(error)"
            }
            busy = false
            await refresh()
        }
    }

    private func note(_ line: String) {
        serialLog.append(line)
    }

    func powerOn(_ target: TargetSummary, millivolts: Int64) {
        perform("Powering on \(target.name)…") { api in
            _ = try await api.power_on(target: target.id, voltage_millivolts: millivolts, settle_ms: 2000)
        }
    }

    func powerOff(_ target: TargetSummary) {
        perform("Powering off \(target.name)…") { api in
            _ = try await api.power_off(target: target.id)
        }
    }

    func emergencyOff(_ target: TargetSummary) {
        perform("Emergency off \(target.name)…") { api in
            _ = try await api.emergency_off(target: target.id)
        }
    }

    func flashWrite(_ target: TargetSummary, firmware: String) {
        perform("Flashing \(target.name)…") { api in
            _ = try await api.flash_write(target: target.id, firmware: firmware, confirm_target: target.id)
        }
    }

    func flashReset(_ target: TargetSummary) {
        perform("Resetting \(target.name)…") { api in
            _ = try await api.flash_reset(target: target.id, confirm_target: target.id)
        }
    }

    func cancel(_ operation: OperationSummary) {
        perform("Cancelling \(operation.id)…") { api in
            _ = try await api.cancel_operation(operation_id: operation.id)
        }
    }

    func serialOpen(_ target: TargetSummary, port: String?, baud: Int64?) {
        perform("Opening serial on \(target.name)…") { api in
            let result = try await api.serial_open(target: target.id, port: port, baud: baud)
            self.note(result.ok
                      ? "open → \(result.port) @ \(result.baud) baud"
                      : "open failed: \(result.error ?? "unknown error")")
        }
    }

    func serialSend(_ target: TargetSummary, data: String) {
        perform("Sending serial data…") { api in
            let result = try await api.serial_send(target: target.id, data: data)
            self.note(result.ok
                      ? "send → queued (observation \(result.observation_id ?? "-"))"
                      : "send failed: \(result.error ?? "unknown error")")
        }
    }

    func serialWait(_ target: TargetSummary, pattern: String, timeoutMs: Int64) {
        perform("Waiting for \"\(pattern)\"…") { api in
            let result = try await api.serial_wait(target: target.id, pattern: pattern, timeout_ms: timeoutMs)
            if result.matched {
                self.note("wait matched after \(result.elapsed_ms) ms: \(result.matched_line ?? "")")
            } else {
                self.note("wait timed out after \(result.elapsed_ms) ms: \(result.error ?? "no match")")
            }
        }
    }

    func serialWindow(_ target: TargetSummary, lines: Int64, filter: String?) {
        perform("Capturing serial window…") { api in
            let result = try await api.serial_window(target: target.id, lines: lines, line_filter: filter)
            if result.ok {
                self.note("window (\(result.lines.count) lines):")
                for line in result.lines { self.note("  \(line)") }
            } else {
                self.note("window failed: \(result.error ?? "unknown error")")
            }
        }
    }

    func udsRequest(_ target: TargetSummary, requestHex: String) {
        perform("UDS request \(requestHex)…") { api in
            let result = try await api.uds_request(target: target.id, request_hex: requestHex,
                                                   p2_timeout_ms: nil, p2_star_timeout_ms: nil)
            self.udsPositive = result.positive
            self.udsResponseHex = result.response_hex
            self.udsNrc = result.nrc
            if !result.ok {
                self.statusText = "UDS error: \(result.error ?? "unknown error")"
            }
        }
    }

    func doipDiscover() {
        perform("Discovering DoIP vehicles…") { api in
            let result = try await api.doip_discover(window_ms: 800)
            self.doipVehicles = result.vehicles
        }
    }

    func dtcRead(_ target: TargetSummary) {
        perform("Reading DTCs from \(target.name)…") { api in
            let result = try await api.dtc_read(target: target.id, status_mask: nil)
            self.dtcs = result.dtcs
            self.dtcAvailableMask = result.available_mask
            self.dtcMessage = result.positive
                ? nil
                : (result.error ?? "The ECU did not answer the DTC read (NRC or unsupported).")
        }
    }

    func dtcClear(_ target: TargetSummary) {
        perform("Clearing DTCs on \(target.name)…") { api in
            let result = try await api.dtc_clear(target: target.id, group: nil)
            if result.positive {
                self.dtcs = []
                self.dtcAvailableMask = nil
                self.dtcMessage = "DTC memory cleared."
            } else {
                self.dtcMessage = result.error ?? "The ECU did not accept the clear request."
            }
        }
    }

    func udsFlash(_ target: TargetSummary, firmware: String, planPath: String?, address: Int64?) {
        perform("UDS flashing \(target.name)…") { api in
            let result = try await api.uds_flash(target: target.id, firmware: firmware,
                                                 plan_path: planPath, address: address,
                                                 max_block_payload: nil, confirm_target: target.id)
            self.flashSteps = result.steps
            self.flashResultLine = result.ok
                ? "UDS flash completed: \(result.total_bytes) bytes in \(result.segment_count) segment(s), \(result.duration_ms) ms."
                : "UDS flash failed: \(result.error ?? "unknown error")"
        }
    }

    func loadEvidence(_ entry: OperationHistoryItem) {
        perform("Loading evidence for \(entry.kind)…") { api in
            self.evidence = try await api.operation_evidence(operation_id: entry.id)
        }
    }

    func cancelObservation(_ observation: ObservationSummary) {
        perform("Cancelling observation \(observation.id)…") { api in
            _ = try await api.cancel_observation(observation_id: observation.id)
        }
    }

    // MARK: - Updates (the taskly family pattern)

    /// Update sheet state machine: mirrors the taskly host's phases.
    enum UpdatePhase {
        case idle
        case checking
        case upToDate
        case available
        case downloading
        case failed
        case notInstalled
    }

    @Published var updateSheetVisible = false
    @Published var updatePhase: UpdatePhase = .idle
    @Published var updateProgressPercent = 0
    @Published var updateAvailableVersion: String?
    @Published var updateErrorMessage = ""

    /// Silent checks run at most once per 4 hours (the family UPDATE
    /// trigger policy). benchpilot-studio has no shared config store yet,
    /// so the mac host keeps its throttle in UserDefaults.
    static let updateThrottleInterval: TimeInterval = 4 * 60 * 60
    private static let lastUpdateCheckKey = "last-update-check"

    /// Manual entry point: app menu ▸ Check for Updates…. The sheet reports
    /// every outcome (up to date, offer, failure, dev copy).
    func checkForUpdates() {
        guard updatePhase != .downloading else { return }
        updateSheetVisible = true
        updatePhase = .checking
        Task { await runUpdateCheck(present: true) }
    }

    /// Silent launch check: once shortly after startup, throttled to one
    /// attempt per 4 h; failures never nag.
    private func autoCheckForUpdates() {
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await runUpdateCheck(present: false)
        }
    }

    private func runUpdateCheck(present: Bool) async {
        guard updatePhase != .downloading else { return }
        if !present {
            guard Self.updateThrottleElapsed() else { return }
        }
        do {
            let result = try await updateService.check()
            Self.recordUpdateCheck()
            switch result {
            case .available(let manifest):
                updateAvailableVersion = manifest.version
                updatePhase = .available
                updateSheetVisible = true
            case .upToDate:
                updatePhase = present ? .upToDate : .idle
                if present { updateSheetVisible = true }
            }
        } catch {
            Self.recordUpdateCheck()
            guard present else {
                updatePhase = .idle
                return
            }
            if case UpdateService.UpdateError.notInstalled = error {
                updatePhase = .notInstalled
            } else {
                updateErrorMessage = Self.cleanError(error)
                updatePhase = .failed
            }
            updateSheetVisible = true
        }
    }

    private static func updateThrottleElapsed() -> Bool {
        let last = UserDefaults.standard.double(forKey: lastUpdateCheckKey)
        return Date().timeIntervalSince1970 - last >= updateThrottleInterval
    }

    private static func recordUpdateCheck() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastUpdateCheckKey)
    }

    /// Offer accepted: download (progress in the sheet) → sha256 + Ed25519
    /// already verified → in-place swap → relaunch. UpdateService terminates
    /// the app on success; any earlier throw leaves this version running.
    func installUpdate() {
        guard case .available = updatePhase else { return }
        updatePhase = .downloading
        updateProgressPercent = 0
        updateErrorMessage = ""
        Task { [weak self] in
            guard let self else { return }
            do {
                // Re-run the check to obtain the manifest for the accepted
                // offer: the sheet carried only the version, the check
                // result stays service-local.
                let manifest = try await self.freshManifest()
                try await self.updateService.downloadAndInstall(manifest) { [weak self] percent in
                    // The download runs off the main actor; hop the
                    // observable write back so SwiftUI sees it.
                    Task { @MainActor [weak self] in
                        self?.updateProgressPercent = percent
                    }
                }
            } catch {
                self.updateErrorMessage = Self.cleanError(error)
                self.updatePhase = .failed
            }
        }
    }

    /// check() again to obtain the manifest for the accepted offer; the
    /// UserDefaults throttle is intentionally bypassed (this is an install,
    /// not a poll) and a version drift simply surfaces as an error that
    /// leaves the current install running.
    private func freshManifest() async throws -> UpdateService.Manifest {
        let result = try await updateService.check()
        if case .available(let manifest) = result {
            return manifest
        }
        throw UpdateService.UpdateError.manifestMissing
    }

    func dismissUpdateSheet() {
        updateSheetVisible = false
        if updatePhase != .downloading {
            updatePhase = .idle
            updateErrorMessage = ""
            updateAvailableVersion = nil
        }
    }

    func openReleasesPage() {
        if let url = URL(string: UpdateService.releasesPage) {
            NSWorkspace.shared.open(url)
        }
    }

    static func cleanError(_ error: Error) -> String {
        let text = error.localizedDescription
        // RVT1/foundation failures arrive as "...error: <message>"; keep the message.
        if let range = text.range(of: "error: ") {
            return String(text[range.upperBound...])
        }
        return text
    }
}
