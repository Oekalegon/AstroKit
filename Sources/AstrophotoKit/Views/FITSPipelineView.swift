import SwiftUI

/// Displays processing history and properties for a processed result (frame or table).
@available(iOS 16.0, macOS 13.0, *)
public struct FITSPipelineView: View {
    let frame: Frame?
    let table: TableData?

    public init(frame: Frame? = nil, table: TableData? = nil) {
        self.frame = frame
        self.table = table
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let frame, let texture = frame.texture {
                    GroupBox("Image Properties") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Width",      value: "\(texture.width) px")
                            InfoRow(label: "Height",     value: "\(texture.height) px")
                            InfoRow(label: "Color Space", value: "\(frame.colorSpace)")
                            InfoRow(label: "Data Type",  value: frame.dataType?.description ?? "Unknown")
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let table, table.dataFrame != nil {
                    GroupBox("Table Properties") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Rows",         value: "\(table.rowCount)")
                            InfoRow(label: "Columns",      value: "\(table.columnCount)")
                            InfoRow(label: "Column Names", value: table.columnNames.joined(separator: ", "))
                        }
                        .padding(.vertical, 4)
                    }
                }

                let hasContent = (frame?.texture != nil) || (table?.dataFrame != nil)
                if !hasContent {
                    Text("No pipeline data available")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .padding()
        }
    }
}
