import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 20) {
            Text("Rivet")
                .font(.largeTitle.bold())

            Text("Racket + SwiftUI")
                .foregroundStyle(.secondary)

            Text("Count: \(model.count)")
                .font(.system(size: 34, weight: .semibold, design: .rounded))

            Button("Increment in Racket") {
                model.increment()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.ready)

            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.ready ? Color.secondary : Color.orange)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
    }
}
