import Foundation
import Metal
import TabularData
import os

/// Processor that fits a parabola to Half-Flux Diameter (HFD) measurements taken at a
/// series of different focuser positions, and returns the predicted optimal focus position.
///
/// The parabola model is: `hfd(p) = a·p² + b·p + c`
/// The vertex (optimal focus) is at: `p_optimal = −b / (2·a)`  (valid only when a > 0)
///
/// Sigma-clipping removes outlier measurements before fitting.
///
/// **Input**
/// - `focus_measurements` (TableData) — a table with columns:
///   - `focuser_position` (Int or Double)
///   - `median_hfd`       (Double)
///
/// The caller builds this table by running the HFD pipeline once per focuser step and
/// collecting the `median_hfd` from each `median_hfd` output table.
///
/// **Parameters**
/// - `min_points`  Int    (default 5)   — minimum data points required for a valid fit.
/// - `sigma_clip`  Double (default 2.5) — sigma multiplier for outlier rejection.
///
/// **Outputs**
/// - `autofocus_result` (TableData) — one summary row.
/// - `fitted_curve`     (TableData) — one row per input data point, for plotting.
public struct AutofocusCurveProcessor: Processor {

    public var id: String { "autofocus_curve" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        guard let measureTable = inputs["focus_measurements"] as? TableData,
              let df = measureTable.dataFrame else {
            throw ProcessorExecutionError.missingRequiredInput("focus_measurements")
        }

        let minPoints = parameters["min_points"]?.intValue  ?? 5
        let sigmaClip = parameters["sigma_clip"]?.doubleValue ?? 2.5

        // Extract (position, hfd) pairs
        guard let posCol = df.columns.first(where: { $0.name == "focuser_position" }),
              let hfdCol = df.columns.first(where: { $0.name == "median_hfd" }) else {
            throw ProcessorExecutionError.executionFailed(
                "focus_measurements table missing 'focuser_position' or 'median_hfd' columns"
            )
        }

        var points: [(position: Double, hfd: Double)] = []
        for i in 0..<df.rows.count {
            let pos: Double
            if let v = posCol[i] as? Double { pos = v }
            else if let v = posCol[i] as? Int { pos = Double(v) }
            else { continue }

            guard let hfd = hfdCol[i] as? Double, hfd > 0 else { continue }
            points.append((position: pos, hfd: hfd))
        }

        // Sort by position
        points.sort { $0.position < $1.position }

        Logger.processor.debug("AutofocusCurveProcessor: \(points.count) data points")

        // Check minimum points
        guard points.count >= minPoints else {
            Logger.processor.warning(
                "AutofocusCurveProcessor: only \(points.count) valid points, need \(minPoints)"
            )
            try writeInvalidResult(outputs: &outputs, points: points, message: "insufficient_data")
            return
        }

        // Sigma-clip outliers on HFD
        let clipped = sigmaClipPoints(points, sigma: sigmaClip)

        guard clipped.count >= minPoints else {
            try writeInvalidResult(outputs: &outputs, points: points, message: "insufficient_data_after_clipping")
            return
        }

        // Fit parabola: hfd = a·p² + b·p + c
        guard let (a, b, c) = fitParabola(clipped) else {
            try writeInvalidResult(outputs: &outputs, points: points, message: "singular_matrix")
            return
        }

        // Validate: parabola must open upward
        guard a > 0 else {
            try writeInvalidResult(outputs: &outputs, points: points, message: "parabola_opens_downward")
            return
        }

        let pOptimal = -b / (2.0 * a)
        let rSquared = computeRSquared(points: clipped, a: a, b: b, c: c)
        let valid    = rSquared >= 0.7

        // Confidence interval: propagate variance from residuals through the normal equations.
        // For the vertex p0 = -b/(2a), σ_p0 ≈ (1/(2a)) * σ_b where σ_b comes from the
        // covariance of the least-squares fit.  As a practical approximation we estimate
        // the step size from the data range and r²:
        let posRange = (clipped.last?.position ?? pOptimal) - (clipped.first?.position ?? pOptimal)
        let confidence = posRange * (1.0 - rSquared) * 0.5

        let afLogMsg = String(
            format: "AutofocusCurveProcessor: optimal position = %.1f, r² = %.4f, valid = %@",
            pOptimal, rSquared, valid ? "true" : "false"
        )
        Logger.processor.info("\(afLogMsg)")

        try writeResult(
            outputs: &outputs,
            optimalPosition: pOptimal,
            a: a, b: b, c: c,
            rSquared: rSquared,
            valid: valid,
            confidence: confidence,
            allPoints: points,
            clippedPoints: clipped
        )
    }

    // MARK: - Sigma Clipping

    private func sigmaClipPoints(
        _ points: [(position: Double, hfd: Double)],
        sigma: Double
    ) -> [(position: Double, hfd: Double)] {
        var current = points
        for _ in 0..<5 {
            let n = Double(current.count)
            guard n > 2 else { break }
            let mean = current.map(\.hfd).reduce(0, +) / n
            let variance = current.map { ($0.hfd - mean) * ($0.hfd - mean) }.reduce(0, +) / n
            let std = sqrt(max(0, variance))
            let lo = mean - sigma * std
            let hi = mean + sigma * std
            let filtered = current.filter { $0.hfd >= lo && $0.hfd <= hi }
            if filtered.count == current.count { break }
            if filtered.count < max(3, current.count / 4) { break }
            current = filtered
        }
        return current
    }

    // MARK: - Parabola Fitting

    /// Fits y = a·x² + b·x + c using least-squares normal equations.
    /// Returns (a, b, c) or nil if the 3×3 system is singular.
    private func fitParabola(
        _ points: [(position: Double, hfd: Double)]
    ) -> (Double, Double, Double)? {
        // Design matrix columns: [p², p, 1]
        // Normal equations: (X'X) * [a,b,c]' = X'y
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0  // Σ p^0..p^4
        var sy0 = 0.0, sy1 = 0.0, sy2 = 0.0                      // Σ y, Σ p·y, Σ p²·y

        for pt in points {
            let p = pt.position, y = pt.hfd
            let p2 = p * p, p3 = p2 * p, p4 = p2 * p2
            s0  += 1
            s1  += p
            s2  += p2
            s3  += p3
            s4  += p4
            sy0 += y
            sy1 += p  * y
            sy2 += p2 * y
        }

        // 3×3 system (row-major):
        //  [ s4  s3  s2 ] [a]   [sy2]
        //  [ s3  s2  s1 ] [b] = [sy1]
        //  [ s2  s1  s0 ] [c]   [sy0]
        var mat: [[Double]] = [
            [s4, s3, s2, sy2],
            [s3, s2, s1, sy1],
            [s2, s1, s0, sy0]
        ]

        // Gaussian elimination with partial pivoting
        for col in 0..<3 {
            // Pivot
            var maxRow = col
            var maxVal = abs(mat[col][col])
            for row in (col + 1)..<3 {
                if abs(mat[row][col]) > maxVal {
                    maxVal = abs(mat[row][col])
                    maxRow = row
                }
            }
            if maxVal < 1e-12 { return nil }  // singular
            if maxRow != col { mat.swapAt(col, maxRow) }

            let pivot = mat[col][col]
            for row in (col + 1)..<3 {
                let factor = mat[row][col] / pivot
                for k in col..<4 {
                    mat[row][k] -= factor * mat[col][k]
                }
            }
        }

        // Back substitution
        var x = [0.0, 0.0, 0.0]
        for i in stride(from: 2, through: 0, by: -1) {
            var sum = mat[i][3]
            for j in (i + 1)..<3 { sum -= mat[i][j] * x[j] }
            guard abs(mat[i][i]) > 1e-12 else { return nil }
            x[i] = sum / mat[i][i]
        }

        return (x[0], x[1], x[2])
    }

    // MARK: - R²

    private func computeRSquared(
        points: [(position: Double, hfd: Double)],
        a: Double, b: Double, c: Double
    ) -> Double {
        let n = Double(points.count)
        let meanY = points.map(\.hfd).reduce(0, +) / n
        let ssTot = points.map { ($0.hfd - meanY) * ($0.hfd - meanY) }.reduce(0, +)
        let ssRes = points.map { pt -> Double in
            let predicted = a * pt.position * pt.position + b * pt.position + c
            return (pt.hfd - predicted) * (pt.hfd - predicted)
        }.reduce(0, +)
        return ssTot > 0 ? 1.0 - ssRes / ssTot : 0.0
    }

    // MARK: - Output Writing

    private func writeResult(
        outputs: inout [String: ProcessData],
        optimalPosition: Double,
        a: Double, b: Double, c: Double,
        rSquared: Double,
        valid: Bool,
        confidence: Double,
        allPoints: [(position: Double, hfd: Double)],
        clippedPoints: [(position: Double, hfd: Double)]
    ) throws {
        if var resultTable = outputs["autofocus_result"] as? TableData {
            var df = DataFrame()
            df.append(column: Column(name: "optimal_position",            contents: [optimalPosition]))
            df.append(column: Column(name: "parabola_a",                  contents: [a]))
            df.append(column: Column(name: "parabola_b",                  contents: [b]))
            df.append(column: Column(name: "parabola_c",                  contents: [c]))
            df.append(column: Column(name: "r_squared",                   contents: [rSquared]))
            df.append(column: Column(name: "valid",                       contents: [valid]))
            df.append(column: Column(name: "optimal_position_confidence", contents: [confidence]))
            resultTable.dataFrame = df
            outputs["autofocus_result"] = resultTable
        }

        if var curveTable = outputs["fitted_curve"] as? TableData {
            let clippedPositions = Set(clippedPoints.map { $0.position })
            var df = DataFrame()
            df.append(column: Column(name: "focuser_position", contents: allPoints.map(\.position)))
            df.append(column: Column(name: "measured_hfd",     contents: allPoints.map(\.hfd)))
            df.append(column: Column(name: "fitted_hfd", contents: allPoints.map { pt in
                a * pt.position * pt.position + b * pt.position + c
            }))
            df.append(column: Column(name: "residual", contents: allPoints.map { pt in
                let fitted = a * pt.position * pt.position + b * pt.position + c
                return pt.hfd - fitted
            }))
            df.append(column: Column(name: "used_in_fit", contents: allPoints.map { pt in
                clippedPositions.contains(pt.position)
            }))
            curveTable.dataFrame = df
            outputs["fitted_curve"] = curveTable
        }
    }

    private func writeInvalidResult(
        outputs: inout [String: ProcessData],
        points: [(position: Double, hfd: Double)],
        message: String
    ) throws {
        if var resultTable = outputs["autofocus_result"] as? TableData {
            var df = DataFrame()
            df.append(column: Column(name: "optimal_position",            contents: [0.0]))
            df.append(column: Column(name: "parabola_a",                  contents: [0.0]))
            df.append(column: Column(name: "parabola_b",                  contents: [0.0]))
            df.append(column: Column(name: "parabola_c",                  contents: [0.0]))
            df.append(column: Column(name: "r_squared",                   contents: [0.0]))
            df.append(column: Column(name: "valid",                       contents: [false]))
            df.append(column: Column(name: "optimal_position_confidence", contents: [0.0]))
            resultTable.dataFrame = df
            outputs["autofocus_result"] = resultTable
        }

        if var curveTable = outputs["fitted_curve"] as? TableData {
            var df = DataFrame()
            df.append(column: Column(name: "focuser_position", contents: points.map(\.position)))
            df.append(column: Column(name: "measured_hfd",     contents: points.map(\.hfd)))
            df.append(column: Column(name: "fitted_hfd",       contents: Array(repeating: 0.0, count: points.count)))
            df.append(column: Column(name: "residual",         contents: Array(repeating: 0.0, count: points.count)))
            df.append(column: Column(name: "used_in_fit",      contents: Array(repeating: false, count: points.count)))
            curveTable.dataFrame = df
            outputs["fitted_curve"] = curveTable
        }

        Logger.processor.warning("AutofocusCurveProcessor: invalid result — \(message)")
    }
}
