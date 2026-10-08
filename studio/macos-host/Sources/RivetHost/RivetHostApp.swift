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
                .frame(minWidth: 520, minHeight: 360)
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
    @Published var status = "Starting embedded Racket CS…"
    @Published var count: Int64 = 0
    @Published var ready = false

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
                    let api = RivetAPI(client: backend.client)
                    let initialCount = try await api.getCounter()
                    await MainActor.run {
                        self.count = initialCount
                        self.ready = true
                        self.status = "Embedded Racket CS is ready"
                    }
                } catch {
                    await MainActor.run {
                        self.ready = false
                        self.status = "Backend error: \(error)"
                    }
                }
            }
        } catch {
            status = "Configuration error: \(error)"
        }
    }

    func increment() {
        guard let backend, ready else { return }
        let next = count + 1

        Task {
            do {
                let api = RivetAPI(client: backend.client)
                count = try await api.setCounter(next)
            } catch {
                status = "State error: \(error)"
            }
        }
    }

}
