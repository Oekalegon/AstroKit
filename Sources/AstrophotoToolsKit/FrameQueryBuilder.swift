import Foundation

// MARK: - Shared date formatter for YYYY-MM-DD MCP/CLI arguments

let ymdFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone(identifier: "UTC")
    return f
}()

// MARK: - Range builders for [String: Any] MCP argument dictionaries

/// Returns a ClosedRange from two optional keys in an MCP argument dictionary.
/// - If both keys are present: lo...hi
/// - If only the min key: lo...Double.infinity
/// - If only the max key: 0...hi
/// - If neither: nil
func doubleRange(_ args: [String: Any], min minKey: String, max maxKey: String,
                 hiOpen: Double = Double.infinity) -> ClosedRange<Double>? {
    switch (args[minKey] as? Double, args[maxKey] as? Double) {
    case let (lo?, hi?): return lo...hi
    case let (lo?, nil): return lo...hiOpen
    case let (nil, hi?): return 0...hi
    default:             return nil
    }
}

/// Returns a ClosedRange from two optional Int keys in an MCP argument dictionary.
/// - If both keys are present: lo...hi
/// - If only the min key: lo...Int.max
/// - If only the max key: 0...hi
/// - If neither: nil
func intRange(_ args: [String: Any], min minKey: String, max maxKey: String) -> ClosedRange<Int>? {
    switch (args[minKey] as? Int, args[maxKey] as? Int) {
    case let (lo?, hi?): return lo...hi
    case let (lo?, nil): return lo...Int.max
    case let (nil, hi?): return 0...hi
    default:             return nil
    }
}

// MARK: - Range builders for typed CLI @Option properties

/// Returns a ClosedRange from two optional Double values (typed CLI @Option properties).
func doubleRange(lo: Double?, hi: Double?, hiOpen: Double = Double.infinity) -> ClosedRange<Double>? {
    switch (lo, hi) {
    case let (lo?, hi?): return lo...hi
    case let (lo?, nil): return lo...hiOpen
    case let (nil, hi?): return 0...hi
    default:             return nil
    }
}

/// Returns a ClosedRange from two optional Int values (typed CLI @Option properties).
func intRange(lo: Int?, hi: Int?, hiOpen: Int = Int.max) -> ClosedRange<Int>? {
    switch (lo, hi) {
    case let (lo?, hi?): return lo...hi
    case let (lo?, nil): return lo...hiOpen
    case let (nil, hi?): return 0...hi
    default:             return nil
    }
}
