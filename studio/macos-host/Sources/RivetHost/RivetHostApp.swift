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
                // URL schemes and file associations are declared from
                // rivet.rktd during packaging. Keep activation handling in the
                // native UI layer; forward only application-level data to the
                // Racket backend when the app actually needs it.
                .onOpenURL { url in activationRouter.handle([url]) }
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

    func start() {
        guard backend == nil else { return }

        do {
            let config = try EmbeddedRacketConfiguration.resolvedDefault(
                moduleName: RivetGeneratedConfig.moduleName,
                entryName: RivetGeneratedConfig.entryName
            )
            let backend = EmbeddedRacketBackend(configuration: config)
            self.backend = backend

            Task.detached { [backend] in
                do {
                    try backend.start()
                    await MainActor.run {
                        self.ready = true
                        self.statusText = "Ready"
                    }
                } catch {
                    await MainActor.run {
                        self.ready = false
                        self.statusText = "Backend error: \(error)"
                    }
                }
            }
        } catch {
            statusText = "Configuration error: \(error)"
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
}
