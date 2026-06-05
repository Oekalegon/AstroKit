import SwiftUI

/// Displays FITS header metadata and image properties.
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
                                InfoRow(label: "BITPIX", value: "\(bitpix)")
                            }
                            InfoRow(label: "Min Value", value: String(format: "%.6f", fitsImage.originalMinValue))
                            InfoRow(label: "Max Value", value: String(format: "%.6f", fitsImage.originalMaxValue))
                        }
                        .padding(.vertical, 4)
                    }

                    GroupBox("FITS Header") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(fitsImage.metadata.keys.sorted()), id: \.self) { key in
                                if let value = fitsImage.metadata[key] {
                                    InfoRow(label: key, value: formatHeaderValue(value))
                                }
                            }
                        }
                        .padding(.vertical, 4)
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

    private func formatHeaderValue(_ value: FITSHeaderValue) -> String {
        switch value {
        case .string(let str):         return str
        case .integer(let int):        return "\(int)"
        case .floatingPoint(let d):    return String(format: "%.6f", d)
        case .boolean(let bool):       return bool ? "T" : "F"
        case .comment(let comment):    return comment
        }
    }
}
