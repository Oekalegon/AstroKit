import Foundation

// MARK: - Shared date formatter for YYYY-MM-DD CLI arguments

let ymdFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

// MARK: - Range builders for typed CLI @Option properties

func doubleRange(lo: Double?, hi: Double?, hiOpen: Double = Double.infinity) -> ClosedRange<Double>? {
    switch (lo, hi) {
    case let (lo?, hi?): return lo...hi
    case let (lo?, nil): return lo...hiOpen
    case let (nil, hi?): return 0...hi
    default:             return nil
    }
}

func intRange(lo: Int?, hi: Int?, hiOpen: Int = Int.max) -> ClosedRange<Int>? {
    switch (lo, hi) {
    case let (lo?, hi?): return lo...hi
    case let (lo?, nil): return lo...hiOpen
    case let (nil, hi?): return 0...hi
    default:             return nil
    }
}
