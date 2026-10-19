import SwiftUI

struct TransferSpeedLimitDialog: View {
    private enum Unit: String, CaseIterable, Identifiable {
        case bytes = "B/s"
        case kilobytes = "KB/s"
        case megabytes = "MB/s"
        case gigabytes = "GB/s"

        var id: String { rawValue }
        var multiplier: Double {
            switch self {
            case .bytes: 1
            case .kilobytes: 1024
            case .megabytes: 1024 * 1024
            case .gigabytes: 1024 * 1024 * 1024
            }
        }
    }

    let controller: TransferController
    @Environment(\.dismiss) private var dismiss
    @State private var usesNoLimit = true
    @State private var amount = "1"
    @State private var unit: Unit = .megabytes
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set Speed Limit").font(.headline)
            Toggle("Do not use speed limit", isOn: $usesNoLimit)
            if !usesNoLimit {
                HStack {
                    TextField("Speed", text: $amount)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 130)
                    Picker("Unit", selection: $unit) {
                        ForEach(Unit.allCases) { item in Text(item.rawValue).tag(item) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Set") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 360)
        .onAppear(perform: loadCurrentLimit)
    }

    private func loadCurrentLimit() {
        guard let current = controller.snapshot.speedLimit else { return }
        usesNoLimit = false
        if current >= Int64(Unit.gigabytes.multiplier) {
            unit = .gigabytes
        } else if current >= Int64(Unit.megabytes.multiplier) {
            unit = .megabytes
        } else if current >= Int64(Unit.kilobytes.multiplier) {
            unit = .kilobytes
        } else {
            unit = .bytes
        }
        let value = Double(current) / unit.multiplier
        amount = value.rounded() == value ? String(Int(value)) : String(value)
    }

    private func apply() {
        if usesNoLimit {
            controller.setSpeedLimit(nil)
            dismiss()
            return
        }
        guard let value = Double(amount.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.isFinite, value > 0, value * unit.multiplier <= Double(Int64.max) else {
            error = "Enter a positive speed limit."
            return
        }
        controller.setSpeedLimit(Int64((value * unit.multiplier).rounded()))
        dismiss()
    }
}
