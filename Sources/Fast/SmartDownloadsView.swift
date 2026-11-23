import AppKit
import SwiftUI

/// Settings › General: which debrid service unlocks magnets and file hosts'
/// links, and its key.
struct SmartDownloadSettings: View {
    @State private var service = Debrid.service
    @State private var key = Debrid.keyFor(Debrid.service) ?? ""

    var body: some View {
        SettingsRow("Debrid service") {
            DropMenu("Debrid service", options: DebridService.allCases.map { (title: $0.title, value: $0) },
                     selection: Binding(get: { service }, set: { picked in
                         service = picked
                         Debrid.service = picked
                         key = Debrid.keyFor(picked) ?? ""
                     }))
                .fixedSize()
        }
        .settingsAnchor("debrid")
        if service != .none {
            SettingsRow("API key") {
                SecureField("API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onChange(of: key) { _, typed in Debrid.setKey(typed, for: service) }
            }
            .settingsAnchor("debrid-key")
        }
    }
}
