import SwiftUI

struct SoftIECDriveRow: View {
    let drive: UltimateAPIClient.DriveInfo
    @ObservedObject var model: DriveBayViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(drive.displayName).font(.headline)
                if let bus = drive.busID { Text("IEC #\(bus)") }
                Spacer()
                Text(drive.enabled ? "IEC Enabled" : "Off IEC Bus").foregroundStyle(.secondary)
            }
            if let error = drive.lastError { Text(error).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            ForEach(drive.partitions, id: \.id) { partition in
                LabeledContent("Partition \(partition.id)", value: partition.path).textSelection(.enabled)
            }
            Button("Reset Software IEC Drive") { Task { await model.reset(drive: "softiec") } }
                .disabled(model.busy || !model.session.isConnected)
            FirmwareSettingSection(api: model.session.api, category: "SoftIEC Drive Settings",
                title: "IEC Mode & Logging",
                footer: "UCI Only keeps the command interface available off the IEC bus. Disabled switches both off. No setting is saved to flash until requested.")
            Button("Manage Partitions in Ultimate Menu…") { model.session.openTelnetMonitor() }
        }.padding(.vertical, 6)
    }
}
