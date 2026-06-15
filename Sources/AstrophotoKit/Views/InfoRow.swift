import SwiftUI

/// A single key-value display row used across the FITS info views
/// (FITSInformationView, FITSPipelineView, FITSImageToolsView).
/// Internal — not part of the public API.
struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.caption).foregroundColor(.secondary)
            Spacer()
            Text(value).font(.caption).fontWeight(.medium)
        }
    }
}
