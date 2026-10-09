import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var firmwarePath = ""
    @State private var firmwareTargetId: String?
    @State private var diagTargetId: String?
    @State private var voltageMillivolts = 12000.0
    @State private var serialPort = ""
    @State private var serialBaud = ""
    @State private var serialSendText = ""
    @State private var serialPattern = ""
    @State private var serialTimeout = "10000"
    @State private var udsRequestHex = ""
    @State private var dtcClearTargetId: String?
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
                    serialSection(status)
                    diagnosticsSection(status)
                    operationsSection
                    observationsSection
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
        .confirmationDialog(
            "Clear DTC memory on \(dtcClearTargetId ?? "")?",
            isPresented: Binding(get: { dtcClearTargetId != nil }, set: { if !$0 { dtcClearTargetId = nil } }),
            titleVisibility: .visible
        ) {
            Button("Clear DTCs", role: .destructive) {
                if let id = dtcClearTargetId, let target = model.runtime?.targets.first(where: { $0.id == id }) {
                    model.dtcClear(target)
                }
                dtcClearTargetId = nil
            }
            Button("Cancel", role: .cancel) { dtcClearTargetId = nil }
        } message: {
            Text("ClearDiagnosticInformation erases every stored DTC on the ECU. This cannot be undone.")
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

    private func serialSection(_ status: RuntimeStatus) -> some View {
        Section("Serial") {
            Picker("Target", selection: Binding(
                get: { diagTargetId ?? status.targets.first?.id },
                set: { diagTargetId = $0 }
            )) {
                ForEach(status.targets, id: \.id) { target in
                    Text(target.name).tag(Optional(target.id))
                }
            }
            HStack(spacing: 8) {
                TextField("port (auto)", text: $serialPort)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 120)
                TextField("baud (auto)", text: $serialBaud)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                Button("Open") {
                    withDiagTarget { model.serialOpen($0,
                                                      port: serialPort.isEmpty ? nil : serialPort,
                                                      baud: Int64(serialBaud)) }
                }
                .disabled(disabled || status.targets.isEmpty)
            }
            HStack(spacing: 8) {
                TextField("data to send", text: $serialSendText)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    withDiagTarget { model.serialSend($0, data: serialSendText) }
                }
                .disabled(disabled || serialSendText.isEmpty || status.targets.isEmpty)
            }
            HStack(spacing: 8) {
                TextField("wait for pattern", text: $serialPattern)
                    .textFieldStyle(.roundedBorder)
                TextField("timeout ms", text: $serialTimeout)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 90)
                Button("Wait") {
                    withDiagTarget { model.serialWait($0,
                                                      pattern: serialPattern,
                                                      timeoutMs: Int64(serialTimeout) ?? 10000) }
                }
                .disabled(disabled || serialPattern.isEmpty || status.targets.isEmpty)
                Button("Capture window") {
                    withDiagTarget { model.serialWindow($0, lines: 50, filter: nil) }
                }
                .disabled(disabled || status.targets.isEmpty)
            }
            if !model.serialLog.isEmpty {
                Text(model.serialLog.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: 120, alignment: .topLeading)
                    .textSelection(.enabled)
            }
        }
    }

    private func diagnosticsSection(_ status: RuntimeStatus) -> some View {
        Section("Diagnostics") {
            HStack(spacing: 8) {
                TextField("UDS request hex, e.g. 22 F1 90", text: $udsRequestHex)
                    .textFieldStyle(.roundedBorder)
                Button("Send") {
                    withDiagTarget { model.udsRequest($0, requestHex: udsRequestHex) }
                }
                .disabled(disabled || udsRequestHex.isEmpty || status.targets.isEmpty)
                Spacer()
                Button("DoIP discover") { model.doipDiscover() }
                    .disabled(disabled)
            }
            if let positive = model.udsPositive {
                HStack(spacing: 8) {
                    Text(positive ? "positive" : "negative")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill((positive ? Color.green : Color.red).opacity(0.18)))
                        .foregroundStyle(positive ? Color.green : Color.red)
                    if let nrc = model.udsNrc {
                        Text("NRC \(nrc)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    if let hex = model.udsResponseHex {
                        Text(hex)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            ForEach(model.doipVehicles, id: \.vin) { vehicle in
                Text("\(vehicle.vin) · \(vehicle.logical_address)\(vehicle.ip_address.map { " · \($0)" } ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: 8) {
                Text("DTC memory")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Read DTCs") {
                    withDiagTarget { model.dtcRead($0) }
                }
                .disabled(disabled || status.targets.isEmpty)
                Button("Clear DTCs", role: .destructive) {
                    dtcClearTargetId = diagTargetId ?? status.targets.first?.id
                }
                .disabled(disabled || status.targets.isEmpty)
            }
            if let mask = model.dtcAvailableMask {
                Text("availability mask \(mask)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.dtcs, id: \.dtc) { entry in
                Text(dtcStatusDescription(entry.status))
                    .font(.caption.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(.leading, 8)
            }
            .padding(.vertical, 2)
            if let message = model.dtcMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// ISO 14229 DTC status byte, decoded to the family's plain-language
    /// flags; 0x00 renders as an empty store.
    private func dtcStatusDescription(_ statusHex: String) -> String {
        guard let value = UInt8(statusHex.dropFirst(2), radix: 16) else {
            return statusHex
        }
        if value == 0 {
            return "\(statusHex) · no faults stored"
        }
        var flags: [String] = []
        if value & 0x01 != 0 { flags.append("testFailed") }
        if value & 0x02 != 0 { flags.append("failedThisOperationCycle") }
        if value & 0x04 != 0 { flags.append("pending") }
        if value & 0x08 != 0 { flags.append("confirmed") }
        if value & 0x10 != 0 { flags.append("testNotCompletedSinceLastClear") }
        if value & 0x20 != 0 { flags.append("testFailedSinceLastClear") }
        if value & 0x40 != 0 { flags.append("testNotCompletedThisOperationCycle") }
        if value & 0x80 != 0 { flags.append("warningIndicatorRequested") }
        return "\(statusHex) · " + flags.joined(separator: ", ")
    }

    private func withDiagTarget(_ body: (TargetSummary) -> Void) {
        if let id = diagTargetId ?? model.runtime?.targets.first?.id,
           let target = model.runtime?.targets.first(where: { $0.id == id }) {
            body(target)
        }
    }

    private var observationsSection: some View {
        Section("Active observations") {
            if model.observations.isEmpty {
                Text("No active observations.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.observations, id: \.id) { observation in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(observation.kind) · \(observation.target_id)")
                            .font(.body.weight(.medium))
                        Text(observation.id)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if observation.cancellation_requested {
                        Text("cancelling")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Button("Cancel") { model.cancelObservation(observation) }
                        .disabled(disabled || observation.cancellation_requested)
                }
            }
        }
    }

    private var operationsSection: some View {        Section("Active operations") {
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
