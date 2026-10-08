import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var firmwarePath = ""
    @State private var firmwareTargetId: String?
    @State private var voltageMillivolts = 12000.0
    @State private var flashTargetId: String?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let status = model.runtime {
                List {
                    targetsSection(status)
                    flashSection(status)
                    operationsSection
                    historySection
                }
            } else {
                emptyState
            }
        }
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel() }
        .confirmationDialog(
            "Write firmware to \(flashTargetId ?? "")?",
            isPresented: Binding(get: { flashTargetId != nil }, set: { if !$0 { flashTargetId = nil } }),
            titleVisibility: .visible
        ) {
            Button("Write firmware", role: .destructive) {
                if let id = flashTargetId, let target = model.runtime?.targets.first(where: { $0.id == id }) {
                    model.flashWrite(target, firmware: firmwarePath)
                }
                flashTargetId = nil
            }
            Button("Cancel", role: .cancel) { flashTargetId = nil }
        } message: {
            Text("The ECU will be erased and reprogrammed. This cannot be cancelled once started.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("BenchPilot Studio")
                    .font(.headline)
                if let status = model.runtime {
                    Text("\(status.name) · runtime \(status.runtime_version ?? "unknown")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.busy {
                ProgressView()
                    .controlSize(.small)
            }
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(model.ready ? Color.secondary : Color.orange)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .controlSize(.small)
            .disabled(!model.ready)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Sections

    private func targetsSection(_ status: RuntimeStatus) -> some View {
        Section("Targets") {
            if status.targets.isEmpty {
                Text("No targets in the runtime profile.")
                    .foregroundStyle(.secondary)
            }
            ForEach(status.targets, id: \.id) { target in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.name)
                                .font(.body.weight(.semibold))
                            Text([target.mcu ?? "unknown MCU", target.id].joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            Button("Power on") { model.powerOn(target, millivolts: Int64(voltageMillivolts)) }
                                .disabled(disabled)
                            Button("Power off") { model.powerOff(target) }
                                .disabled(disabled)
                            Button("Emergency off", role: .destructive) { model.emergencyOff(target) }
                                .disabled(disabled)
                        }
                    }
                    if !target.capabilities.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(target.capabilities, id: \.self) { capability in
                                Text(capability)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            HStack {
                Text("Voltage")
                    .foregroundStyle(.secondary)
                Slider(value: $voltageMillivolts, in: 3000...24000, step: 500)
                    .frame(maxWidth: 220)
                Text("\(voltageMillivolts / 1000, specifier: "%.1f") V")
                    .monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
            }
        }
    }

    private func flashSection(_ status: RuntimeStatus) -> some View {
        Section("Flash") {
            Picker("Target", selection: Binding(
                get: { firmwareTargetId ?? status.targets.first?.id },
                set: { firmwareTargetId = $0 }
            )) {
                ForEach(status.targets, id: \.id) { target in
                    Text(target.name).tag(Optional(target.id))
                }
            }
            HStack {
                TextField("/path/to/firmware.hex", text: $firmwarePath)
                    .textFieldStyle(.roundedBorder)
                Button("Write…", role: .destructive) {
                    flashTargetId = firmwareTargetId ?? status.targets.first?.id
                }
                .disabled(disabled || firmwarePath.isEmpty || status.targets.isEmpty)
                Button("Reset") {
                    if let id = firmwareTargetId ?? status.targets.first?.id,
                       let target = model.runtime?.targets.first(where: { $0.id == id }) {
                        model.flashReset(target)
                    }
                }
                .disabled(disabled || status.targets.isEmpty)
            }
        }
    }

    private var operationsSection: some View {
        Section("Active operations") {
            if model.operations.isEmpty {
                Text("No active operations.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.operations, id: \.id) { operation in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(operation.kind) · \(operation.target_id)")
                            .font(.body.weight(.medium))
                        Text(operation.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if operation.cancellation_requested {
                        Text("cancelling")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if operation.deadline_exceeded {
                        Text("deadline exceeded")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Button("Cancel") { model.cancel(operation) }
                        .disabled(disabled || operation.cancellation_requested)
                }
            }
        }
    }

    private var historySection: some View {
        Section("Recent history") {
            if model.history.isEmpty {
                Text("No completed operations yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.history, id: \.id) { entry in
                HStack {
                    stateBadge(entry.state)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(entry.kind) · \(entry.target_id)")
                            .font(.body.weight(.medium))
                        Text("\(entry.completed_at_utc) · \(entry.duration_ms) ms")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let error = entry.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var disabled: Bool {
        !model.ready || model.busy
    }

    private func stateBadge(_ state: String) -> some View {
        let color: Color = {
            switch state {
            case "succeeded": return .green
            case "failed": return .red
            case "cancelled": return .orange
            default: return .secondary
            }
        }()
        return Text(state)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("BenchPilot Runtime is not reachable")
                .font(.title3.weight(.medium))
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            Button("Retry") {
                Task { await model.refresh() }
            }
            .disabled(!model.ready)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
}
