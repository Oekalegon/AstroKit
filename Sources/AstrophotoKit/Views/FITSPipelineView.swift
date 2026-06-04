import SwiftUI

/// Displays processing history and properties for a processed result (image, table, or scalar).
@available(iOS 16.0, macOS 13.0, *)
public struct FITSPipelineView: View {
    let processedImage: ProcessedImage?
    let processedTable: ProcessedTable?
    let processedScalar: ProcessedScalar?

    public init(processedImage: ProcessedImage? = nil, processedTable: ProcessedTable? = nil, processedScalar: ProcessedScalar? = nil) {
        self.processedImage = processedImage
        self.processedTable = processedTable
        self.processedScalar = processedScalar
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let processedImage = processedImage {
                    GroupBox("Image Properties") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Name",       value: processedImage.name)
                            InfoRow(label: "Image Type", value: processedImage.imageType.rawValue.capitalized)
                            InfoRow(label: "Width",      value: "\(processedImage.width) px")
                            InfoRow(label: "Height",     value: "\(processedImage.height) px")
                            InfoRow(label: "Min Value",  value: String(format: "%.6f", processedImage.originalMinValue))
                            InfoRow(label: "Max Value",  value: String(format: "%.6f", processedImage.originalMaxValue))
                        }
                        .padding(.vertical, 4)
                    }
                    processingHistoryBox(processedImage.processingHistory, emptyMessage: "No processing steps applied (original image)")

                } else if let processedTable = processedTable {
                    GroupBox("Table Properties") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Name", value: processedTable.name)
                            if let count = processedTable.data["component_count"] as? Int {
                                InfoRow(label: "Component Count", value: "\(count)")
                            }
                            if let total = processedTable.data["total_pixels"] as? Int {
                                InfoRow(label: "Total Pixels", value: "\(total)")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    processingHistoryBox(processedTable.processingHistory, emptyMessage: "No processing steps applied")

                } else if let processedScalar = processedScalar {
                    GroupBox("Scalar Properties") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Name",  value: processedScalar.name)
                            InfoRow(label: "Value", value: String(format: "%.6f", processedScalar.value))
                            if let unit = processedScalar.unit {
                                InfoRow(label: "Unit", value: unit)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    processingHistoryBox(processedScalar.processingHistory, emptyMessage: "No processing steps applied (original scalar)")

                } else {
                    Text("No processed data metadata available")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func processingHistoryBox(_ history: [ProcessingStep], emptyMessage: String) -> some View {
        if history.isEmpty {
            GroupBox("Processing History") {
                Text(emptyMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
        } else {
            GroupBox("Processing History") {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(history.enumerated()), id: \.offset) { index, step in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("\(index + 1).")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(step.stepName)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            if !step.parameters.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(step.parameters.keys.sorted()), id: \.self) { key in
                                        if let value = step.parameters[key] {
                                            HStack {
                                                Text("  • \(key):")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                                Text(value)
                                                    .font(.caption2)
                                                    .fontWeight(.medium)
                                                Spacer()
                                            }
                                        }
                                    }
                                }
                                .padding(.leading, 16)
                            }
                        }
                        .padding(.vertical, 4)

                        if index < history.count - 1 {
                            Divider()
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
