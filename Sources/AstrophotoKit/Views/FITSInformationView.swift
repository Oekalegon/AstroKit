import SwiftUI

/// Displays FITS header metadata and image properties, grouped by topic
/// (object, observation, telescope, camera, …) with human readable names.
@available(iOS 16.0, macOS 13.0, *)
public struct FITSInformationView: View {
    let fitsImage: FITSImage?

    public init(fitsImage: FITSImage? = nil) {
        self.fitsImage = fitsImage
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let fitsImage = fitsImage {
                    GroupBox("Image Properties") {
                        VStack(alignment: .leading, spacing: 8) {
                            InfoRow(label: "Width", value: "\(fitsImage.width) px")
                            InfoRow(label: "Height", value: "\(fitsImage.height) px")
                            if fitsImage.depth > 1 {
                                InfoRow(label: "Depth", value: "\(fitsImage.depth)")
                            }
                            InfoRow(label: "Total Pixels", value: "\(fitsImage.width * fitsImage.height)")
                            InfoRow(label: "Data Type", value: fitsImage.dataType.description)
                            if let bitpix = fitsImage.metadata["BITPIX"]?.intValue {
                                InfoRow(label: "Bits per Pixel", value: "\(bitpix)")
                            }
                            InfoRow(label: "Min Value", value: String(format: "%.6f", fitsImage.originalMinValue))
                            InfoRow(label: "Max Value", value: String(format: "%.6f", fitsImage.originalMaxValue))
                        }
                        .padding(.vertical, 4)
                    }

                    ForEach(FITSKeywordCatalog.groupedSections(from: fitsImage.metadata), id: \.group) { section in
                        GroupBox(section.group.rawValue) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(section.entries, id: \.keyword) { entry in
                                    InfoRow(label: entry.displayName, value: entry.displayValue)
                                        .help(entry.keyword)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } else {
                    Text("No FITS image loaded")
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                }
            }
            .padding()
        }
    }

}
