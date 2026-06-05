import Foundation

extension FITSFile {
    /// Reads image dimensions and bit depth from the current HDU without loading pixel data.
    public func readImageParameters() throws -> (width: Int, height: Int, bitpix: Int32) {
        guard let file = fitsfile else {
            throw FITSFileError.fileNotOpen
        }

        var status: Int32 = 0
        var bitpix: Int32 = 0
        var naxis: Int32 = 0
        var naxesArray = [Int64](repeating: 0, count: 3)

        _ = getImageParameters(file, 3, &bitpix, &naxis, &naxesArray, &status)

        guard status == 0 else {
            var errorText = [CChar](repeating: 0, count: 81)
            getFITSErrorStatus(status, &errorText)
            errorText[80] = 0
            throw FITSFileError.readError(status: status, message: String(cString: errorText))
        }

        let width  = naxis > 0 ? Int(naxesArray[0]) : 0
        let height = naxis > 1 ? Int(naxesArray[1]) : 0
        return (width, height, bitpix)
    }
}
