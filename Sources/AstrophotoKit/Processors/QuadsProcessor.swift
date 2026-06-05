import Foundation
import Metal
import os
import TabularData

/// Represents a star with its coordinates and properties
private struct StarInfo {
    // swiftlint:disable identifier_name
    let x: Double
    let y: Double
    // swiftlint:enable identifier_name
    let area: Int
    let id: Int
}

/// Represents the 6 pairwise distances between 4 stars in a quad
private struct QuadDistances {
    let d12: Double  // Distance between star1 and star2
    let d13: Double  // Distance between star1 and star3
    let d14: Double  // Distance between star1 and star4
    let d23: Double  // Distance between star2 and star3
    let d24: Double  // Distance between star2 and star4
    let d34: Double  // Distance between star3 and star4
}

/// Represents normalized coordinates for a star in a canonical quad
private struct NormalizedStar {
    // swiftlint:disable identifier_name
    let x: Double
    let y: Double
    // swiftlint:enable identifier_name
}

/// Represents a quad with 4 stars and their distances
private struct Quad {
    let star1: StarInfo
    let star2: StarInfo
    let star3: StarInfo
    let star4: StarInfo
    let distances: QuadDistances
    let normalized: NormalizedQuad
    // Stars in normalized order: S1 (baseline), S2 (baseline), S3, S4
    // swiftlint:disable identifier_name
    let s1: StarInfo  // Baseline star 1 (longest distance pair)
    let s2: StarInfo  // Baseline star 2 (longest distance pair)
    let s3: StarInfo  // Other star 1
    let s4: StarInfo  // Other star 2
    // swiftlint:enable identifier_name

    /// Normalized quad with baseline on x-axis
    struct NormalizedQuad {
        // swiftlint:disable identifier_name
        let s1: NormalizedStar  // Always (0, 0)
        let s2: NormalizedStar  // Always (1, 0)
        let s3: NormalizedStar  // Normalized position
        let s4: NormalizedStar  // Normalized position
        // swiftlint:enable identifier_name
    }
}

/// Processor that creates quads from detected stars for pattern matching
public struct QuadsProcessor: Processor {
    public var id: String { "quads" }

    public init() {}

    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        // Extract pixel_coordinates table
        guard let pixelCoordinatesTable = inputs["pixel_coordinates"] as? TableData,
              let dataFrame = pixelCoordinatesTable.dataFrame else {
            throw ProcessorExecutionError.missingRequiredInput("pixel_coordinates")
        }

        // Extract parameters
        let maxStars = extractIntParameter(parameters, name: "max_stars", defaultValue: 50)
        let minDistancePercent = extractDoubleParameter(parameters, name: "min_distance_percent", defaultValue: 0.0)
        let kNeighbors = extractIntParameter(parameters, name: "k_neighbors", defaultValue: 5)

        // Get image dimensions from input frame if available
        let imageDimensions = getImageDimensions(from: inputs)

        // Extract star information from DataFrame
        let stars = try extractStars(from: dataFrame)

        // Select brightest stars with minimum distance constraint
        let selectedStars = selectBrightestStarsWithDistance(
            stars: stars,
            maxStars: maxStars,
            minDistancePercent: minDistancePercent,
            imageWidth: imageDimensions.width,
            imageHeight: imageDimensions.height
        )

        // Create quads using k-nearest neighbors
        let quads = createQuadsFromNeighbors(
            selectedStars: selectedStars,
            kNeighbors: kNeighbors
        )

        // Create output DataFrame
        if var outputTable = outputs["quads"] as? TableData {
            let quadDataFrame = createQuadDataFrame(quads: quads)
            outputTable.dataFrame = quadDataFrame
            outputs["quads"] = outputTable
        }
    }

    // MARK: - Private Helper Methods

    private func extractIntParameter(_ parameters: [String: Parameter], name: String, defaultValue: Int) -> Int {
        if let param = parameters[name],
           case .int(let value) = param {
            return value
        }
        return defaultValue
    }

    private func extractDoubleParameter(_ parameters: [String: Parameter], name: String, defaultValue: Double) -> Double {
        if let param = parameters[name],
           case .double(let value) = param {
            return value
        }
        return defaultValue
    }

    private func getImageDimensions(from inputs: [String: ProcessData]) -> (width: Int, height: Int) {
        // Try to get dimensions from input frame
        if let inputFrame = inputs["input_frame"] as? Frame,
           let texture = inputFrame.texture {
            return (texture.width, texture.height)
        }

        // Fallback: use default dimensions
        return (4096, 4096)
    }

    private func extractStars(from dataFrame: DataFrame) throws -> [StarInfo] {
        guard let idColumn = dataFrame.columns.first(where: { $0.name == "id" }),
              let areaColumn = dataFrame.columns.first(where: { $0.name == "area" }),
              let centroidXColumn = dataFrame.columns.first(where: { $0.name == "centroid_x" }),
              let centroidYColumn = dataFrame.columns.first(where: { $0.name == "centroid_y" }) else {
            throw ProcessorExecutionError.executionFailed("Missing required columns in pixel_coordinates table")
        }

        var stars: [StarInfo] = []
        for rowIndex in 0..<dataFrame.rows.count {
            guard let id = idColumn[rowIndex] as? Int,
                  let area = areaColumn[rowIndex] as? Int,
                  let centroidX = centroidXColumn[rowIndex] as? Double,
                  let centroidY = centroidYColumn[rowIndex] as? Double else {
                continue
            }

            stars.append(StarInfo(
                x: centroidX,
                y: centroidY,
                area: area,
                id: id
            ))
        }

        return stars
    }

    private func selectBrightestStarsWithDistance(
        stars: [StarInfo],
        maxStars: Int,
        minDistancePercent: Double,
        imageWidth: Int,
        imageHeight: Int
    ) -> [StarInfo] {
        // If no minimum distance specified, just select brightest stars
        guard minDistancePercent > 0.0 else {
            return Array(stars.sorted { $0.area > $1.area }.prefix(maxStars))
        }

        // Calculate minimum distance in pixels using Taxicab (Manhattan) distance
        let imageDiagonal = Double(imageWidth + imageHeight)
        let minDistancePixels = imageDiagonal * minDistancePercent / 100.0

        // Sort by brightness (area)
        let sortedStars = stars.sorted { $0.area > $1.area }

        // Greedy selection using k-d tree for efficient distance checks
        var selected: [StarInfo] = []
        var selectedPoints: [Point2D] = []
        let kdTree = KDTree()

        for star in sortedStars {
            guard selected.count < maxStars else {
                break
            }

            let candidatePoint = Point2D(x: star.x, y: star.y)

            // Use k-d tree to check if any selected point is too close
            let hasNearbyPoint = kdTree.hasPointWithinDistance(
                from: candidatePoint,
                maxDistance: minDistancePixels
            )

            // If far enough from all selected stars, add to selection
            if !hasNearbyPoint {
                selected.append(star)
                selectedPoints.append(candidatePoint)

                // Rebuild k-d tree with new point
                kdTree.buildTree(points: selectedPoints)
            }
        }

        return selected
    }

    private func createQuadsFromNeighbors(
        selectedStars: [StarInfo],
        kNeighbors: Int
    ) -> [Quad] {
        guard !selectedStars.isEmpty, kNeighbors > 0 else {
            return []
        }

        // Extract points and create mapping from points to stars
        var pointToStar: [Point2D: StarInfo] = [:]
        var points: [Point2D] = []

        for star in selectedStars {
            let point = Point2D(x: star.x, y: star.y)
            pointToStar[point] = star
            points.append(point)
        }

        // Build k-d tree from all selected points
        let kdTree = KDTree(points: points)

        // For each seed star, find its k nearest neighbors and create quad lists
        var allQuads: [Quad] = []
        var seenDescriptors: Set<String> = []

        for point in points {
            // Find k nearest neighbors (including the point itself)
            let neighbors = kdTree.kNearestNeighbors(to: point, k: min(kNeighbors + 1, points.count))

            // Filter out the point itself
            let neighborPoints = neighbors.filter { $0 != point }

            // Need at least 3 neighbors to form quads (seed + 3 neighbors = 4 stars)
            guard neighborPoints.count >= 3 else {
                continue
            }

            // Get seed star
            guard let seedStar = pointToStar[point] else {
                continue
            }

            // Convert neighbor points to StarInfo
            let neighborStars = neighborPoints.prefix(kNeighbors).compactMap { neighborPoint -> StarInfo? in
                return pointToStar[neighborPoint]
            }

            guard neighborStars.count >= 3 else {
                continue
            }

            // Generate all combinations of 3 neighbors to create quads
            let quadLists = generateQuadCombinations(
                seed: seedStar,
                neighbors: neighborStars
            )

            // Add quads, deduplicating by descriptor
            for quad in quadLists {
                let descriptor = createDescriptorKey(from: quad)
                if !seenDescriptors.contains(descriptor) {
                    seenDescriptors.insert(descriptor)
                    allQuads.append(quad)
                }
            }
        }

        return allQuads
    }

    /// Generate all combinations of 4 stars: seed + 3 neighbors
    private func generateQuadCombinations(
        seed: StarInfo,
        neighbors: [StarInfo]
    ) -> [Quad] {
        guard neighbors.count >= 3 else {
            return []
        }

        var quadLists: [Quad] = []

        // Generate all combinations of 3 neighbors (C(n, 3))
        for index1 in 0..<neighbors.count {
            for index2 in (index1 + 1)..<neighbors.count {
                for index3 in (index2 + 1)..<neighbors.count {
                    // Create a quad: {seed, neighbor[index1], neighbor[index2], neighbor[index3]}
                    let star1 = seed
                    let star2 = neighbors[index1]
                    let star3 = neighbors[index2]
                    let star4 = neighbors[index3]

                    // Calculate the 6 distances between the 4 stars
                    let distances = calculateQuadDistances(
                        star1: star1,
                        star2: star2,
                        star3: star3,
                        star4: star4
                    )

                    // Calculate normalized coordinates with longest distance as baseline
                    let normalizedResult = calculateNormalizedCoordinates(
                        star1: star1,
                        star2: star2,
                        star3: star3,
                        star4: star4,
                        distances: distances
                    )

                    let quad = Quad(
                        star1: star1,
                        star2: star2,
                        star3: star3,
                        star4: star4,
                        distances: distances,
                        normalized: normalizedResult.normalized,
                        s1: normalizedResult.s1,
                        s2: normalizedResult.s2,
                        s3: normalizedResult.s3,
                        s4: normalizedResult.s4
                    )

                    quadLists.append(quad)
                }
            }
        }

        return quadLists
    }

    /// Calculate the 6 pairwise distances between 4 stars in a quad
    private func calculateQuadDistances(
        star1: StarInfo,
        star2: StarInfo,
        star3: StarInfo,
        star4: StarInfo
    ) -> QuadDistances {
        // Calculate 6 pairwise distances using Euclidean distance
        let d12 = euclideanDistance((x: star1.x, y: star1.y), (x: star2.x, y: star2.y))
        let d13 = euclideanDistance((x: star1.x, y: star1.y), (x: star3.x, y: star3.y))
        let d14 = euclideanDistance((x: star1.x, y: star1.y), (x: star4.x, y: star4.y))
        let d23 = euclideanDistance((x: star2.x, y: star2.y), (x: star3.x, y: star3.y))
        let d24 = euclideanDistance((x: star2.x, y: star2.y), (x: star4.x, y: star4.y))
        let d34 = euclideanDistance((x: star3.x, y: star3.y), (x: star4.x, y: star4.y))

        return QuadDistances(
            d12: d12,
            d13: d13,
            d14: d14,
            d23: d23,
            d24: d24,
            d34: d34
        )
    }

    /// Calculate Euclidean distance between two points
    private func euclideanDistance(_ point1: (x: Double, y: Double), _ point2: (x: Double, y: Double)) -> Double {
        let deltaX = point1.x - point2.x
        let deltaY = point1.y - point2.y
        return sqrt(deltaX * deltaX + deltaY * deltaY)
    }

    /// Result of normalization containing normalized coordinates and ordered stars
    private struct NormalizationResult {
        let normalized: Quad.NormalizedQuad
        // swiftlint:disable identifier_name
        let s1: StarInfo  // Baseline star 1 (canonical order)
        let s2: StarInfo  // Baseline star 2 (canonical order)
        let s3: StarInfo  // Other star 1 (canonical order)
        let s4: StarInfo  // Other star 2 (canonical order)
        // swiftlint:enable identifier_name
    }

    // swiftlint:disable identifier_name
    /// Variant type for canonical ordering
    private enum VariantType {
        case v0  // (x3, y3, x4, y4) - original
        case v1  // (1-x3, -y3, 1-x4, -y4) - swap S1/S2 and reflect
        case v2  // (x3, -y3, x4, -y4) - reflect across x-axis
        case v3  // (1-x3, y3, 1-x4, y4) - swap S1/S2 only
    }
    // swiftlint:enable identifier_name

    /// Represents a variant descriptor
    private struct VariantDescriptor {
        // swiftlint:disable identifier_name
        let x3: Double
        let y3: Double
        let x4: Double
        let y4: Double
        // swiftlint:enable identifier_name
        let variant: VariantType
    }

    /// Distance pair for baseline selection
    private struct DistancePair {
        let label: String
        let distance: Double
        let star1: StarInfo
        let star2: StarInfo
    }

    /// Calculate normalized coordinates with longest distance as baseline
    private func calculateNormalizedCoordinates(
        star1: StarInfo,
        star2: StarInfo,
        star3: StarInfo,
        star4: StarInfo,
        distances: QuadDistances
    ) -> NormalizationResult {
        // Find the longest distance to determine baseline
        let allDistances = [
            DistancePair(label: "12", distance: distances.d12, star1: star1, star2: star2),
            DistancePair(label: "13", distance: distances.d13, star1: star1, star2: star3),
            DistancePair(label: "14", distance: distances.d14, star1: star1, star2: star4),
            DistancePair(label: "23", distance: distances.d23, star1: star2, star2: star3),
            DistancePair(label: "24", distance: distances.d24, star1: star2, star2: star4),
            DistancePair(label: "34", distance: distances.d34, star1: star3, star2: star4)
        ]

        // Find the pair with maximum distance
        guard let maxPair = allDistances.max(by: { $0.distance < $1.distance }) else {
            // Fallback: use original star1, star2 as baseline
            let result = normalizeQuad(
                s1: star1,
                s2: star2,
                s3: star3,
                s4: star4
            )
            return NormalizationResult(
                normalized: result.normalized,
                s1: star1,
                s2: star2,
                s3: star3,
                s4: star4
            )
        }

        // maxPair.star1 and maxPair.star2 are the two stars with longest distance (S1 and S2)
        let baselineStar1 = maxPair.star1
        let baselineStar2 = maxPair.star2

        // The other two stars become S3 and S4
        let otherStars = [star1, star2, star3, star4].filter { star in
            !(star.x == baselineStar1.x && star.y == baselineStar1.y) &&
            !(star.x == baselineStar2.x && star.y == baselineStar2.y)
        }

        guard otherStars.count == 2 else {
            // Fallback: use original star1, star2 as baseline
            let result = normalizeQuad(
                s1: star1,
                s2: star2,
                s3: star3,
                s4: star4
            )
            return NormalizationResult(
                normalized: result.normalized,
                s1: star1,
                s2: star2,
                s3: star3,
                s4: star4
            )
        }

        let result = normalizeQuad(
            s1: baselineStar1,
            s2: baselineStar2,
            s3: otherStars[0],
            s4: otherStars[1]
        )

        return NormalizationResult(
            normalized: result.normalized,
            s1: baselineStar1,
            s2: baselineStar2,
            s3: otherStars[0],
            s4: otherStars[1]
        )
    }

    /// Result of normalization with variant information
    private struct NormalizedQuadResult {
        let normalized: Quad.NormalizedQuad
        let variant: VariantType
    }

    // swiftlint:disable identifier_name
    /// Normalize a quad so that S1 is at (0,0), S2 is at (1,0)
    /// Returns the canonical (lexicographically smallest) variant
    private func normalizeQuad(
        s1: StarInfo,
        s2: StarInfo,
        s3: StarInfo,
        s4: StarInfo
    ) -> NormalizedQuadResult {
    // swiftlint:enable identifier_name
        // Step 1: Translate so S1 is at origin
        let s2Translated = (x: s2.x - s1.x, y: s2.y - s1.y)
        let s3Translated = (x: s3.x - s1.x, y: s3.y - s1.y)
        let s4Translated = (x: s4.x - s1.x, y: s4.y - s1.y)

        // Step 2: Calculate baseline distance and angle
        let baselineDistance = sqrt(s2Translated.x * s2Translated.x + s2Translated.y * s2Translated.y)
        guard baselineDistance > 0 else {
            // Degenerate case: return identity
            return NormalizedQuadResult(
                normalized: Quad.NormalizedQuad(
                    s1: NormalizedStar(x: 0.0, y: 0.0),
                    s2: NormalizedStar(x: 1.0, y: 0.0),
                    s3: NormalizedStar(x: 0.0, y: 0.0),
                    s4: NormalizedStar(x: 0.0, y: 0.0)
                ),
                variant: .v0
            )
        }

        let angle = atan2(s2Translated.y, s2Translated.x)
        let cosAngle = cos(-angle)  // Negative to rotate back
        let sinAngle = sin(-angle)

        // Step 3: Rotate so baseline is on x-axis
        let s3Rotated = (
            x: s3Translated.x * cosAngle - s3Translated.y * sinAngle,
            y: s3Translated.x * sinAngle + s3Translated.y * cosAngle
        )
        let s4Rotated = (
            x: s4Translated.x * cosAngle - s4Translated.y * sinAngle,
            y: s4Translated.x * sinAngle + s4Translated.y * cosAngle
        )

        // Step 4: Scale so baseline distance = 1.0
        let scale = 1.0 / baselineDistance

        // Calculate normalized coordinates
        // swiftlint:disable identifier_name
        let x3 = s3Rotated.x * scale
        let y3 = s3Rotated.y * scale
        let x4 = s4Rotated.x * scale
        let y4 = s4Rotated.y * scale
        // swiftlint:enable identifier_name

        // Generate all variants and find lexicographically smallest
        let variants: [VariantDescriptor] = [
            VariantDescriptor(x3: x3, y3: y3, x4: x4, y4: y4, variant: .v0),
            VariantDescriptor(x3: 1.0 - x3, y3: -y3, x4: 1.0 - x4, y4: -y4, variant: .v1),
            VariantDescriptor(x3: x3, y3: -y3, x4: x4, y4: -y4, variant: .v2),
            VariantDescriptor(x3: 1.0 - x3, y3: y3, x4: 1.0 - x4, y4: y4, variant: .v3)
        ]

        // Find lexicographically smallest variant
        let canonical = variants.min { variant1, variant2 in
            // Compare lexicographically: first x3, then y3, then x4, then y4
            if variant1.x3 != variant2.x3 { return variant1.x3 < variant2.x3 }
            if variant1.y3 != variant2.y3 { return variant1.y3 < variant2.y3 }
            if variant1.x4 != variant2.x4 { return variant1.x4 < variant2.x4 }
            return variant1.y4 < variant2.y4
        }!

        return NormalizedQuadResult(
            normalized: Quad.NormalizedQuad(
                s1: NormalizedStar(x: 0.0, y: 0.0),
                s2: NormalizedStar(x: 1.0, y: 0.0),
                s3: NormalizedStar(x: canonical.x3, y: canonical.y3),
                s4: NormalizedStar(x: canonical.x4, y: canonical.y4)
            ),
            variant: canonical.variant
        )
    }

    /// Create a descriptor key for deduplication
    private func createDescriptorKey(from quad: Quad) -> String {
        let s3 = quad.normalized.s3
        let s4 = quad.normalized.s4
        // Use a precision that allows for reasonable matching
        return String(format: "%.6f,%.6f,%.6f,%.6f", s3.x, s3.y, s4.x, s4.y)
    }

    /// Create DataFrame from quads
    private func createQuadDataFrame(quads: [Quad]) -> DataFrame {
        var dataFrame = DataFrame()

        // Add ID column
        dataFrame.append(column: Column(name: "id", contents: Array(0..<quads.count)))

        // Add descriptor columns (normalized coordinates of S3 and S4)
        dataFrame.append(column: Column(
            name: "descriptor_x3",
            contents: quads.map { $0.normalized.s3.x }
        ))
        dataFrame.append(column: Column(
            name: "descriptor_y3",
            contents: quads.map { $0.normalized.s3.y }
        ))
        dataFrame.append(column: Column(
            name: "descriptor_x4",
            contents: quads.map { $0.normalized.s4.x }
        ))
        dataFrame.append(column: Column(
            name: "descriptor_y4",
            contents: quads.map { $0.normalized.s4.y }
        ))

        // Add image coordinates for each star
        dataFrame.append(column: Column(
            name: "s1_x",
            contents: quads.map { $0.s1.x }
        ))
        dataFrame.append(column: Column(
            name: "s1_y",
            contents: quads.map { $0.s1.y }
        ))
        dataFrame.append(column: Column(
            name: "s2_x",
            contents: quads.map { $0.s2.x }
        ))
        dataFrame.append(column: Column(
            name: "s2_y",
            contents: quads.map { $0.s2.y }
        ))
        dataFrame.append(column: Column(
            name: "s3_x",
            contents: quads.map { $0.s3.x }
        ))
        dataFrame.append(column: Column(
            name: "s3_y",
            contents: quads.map { $0.s3.y }
        ))
        dataFrame.append(column: Column(
            name: "s4_x",
            contents: quads.map { $0.s4.x }
        ))
        dataFrame.append(column: Column(
            name: "s4_y",
            contents: quads.map { $0.s4.y }
        ))

        // Add star IDs
        dataFrame.append(column: Column(
            name: "s1_id",
            contents: quads.map { $0.s1.id }
        ))
        dataFrame.append(column: Column(
            name: "s2_id",
            contents: quads.map { $0.s2.id }
        ))
        dataFrame.append(column: Column(
            name: "s3_id",
            contents: quads.map { $0.s3.id }
        ))
        dataFrame.append(column: Column(
            name: "s4_id",
            contents: quads.map { $0.s4.id }
        ))

        return dataFrame
    }
}

