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
    @Published var history: [OperationHistoryItem] = []
    @Published var busy = false

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
            let past = try await api.operation_history(limit: 25)
            runtime = status
            operations = active
            history = past
            statusText = "Connected"
        } catch {
            runtime = nil
            operations = []
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
}
