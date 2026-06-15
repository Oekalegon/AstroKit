import Foundation
import Metal

/// Represents a star with its coordinates and properties
private struct StarInfo {
    // swiftlint:disable identifier_name
    let x: Double
    let y: Double
    // swiftlint:enable identifier_name
    let area: Int
    let isSeed: Bool

    /// Convert to dictionary for output
    func toDictionary() -> [String: Any] {
        return [
            "x": x,
            "y": y,
            "area": area,
            "is_seed": isSeed
        ]
    }

    /// Create from component dictionary
    init?(from component: [String: Any], isSeed: Bool) {
        self.isSeed = isSeed
        self.area = component["area"] as? Int ?? 0

        if let centroid = component["centroid"] as? [String: Any] {
            guard let centroidX = centroid["x"] as? Double,
                  let centroidY = centroid["y"] as? Double else {
                return nil
            }
            self.x = centroidX
            self.y = centroidY
        } else {
            self.x = 0.0
            self.y = 0.0
        }
    }
}

/// Represents the 6 pairwise distances between 4 stars in a quad
private struct QuadDistances {
    let d12: Double  // Distance between star1 and star2
    let d13: Double  // Distance between star1 and star3
    let d14: Double  // Distance between star1 and star4
    let d23: Double  // Distance between star2 and star3
    let d24: Double  // Distance between star2 and star4
    let d34: Double  // Distance between star3 and star4

    /// Convert to dictionary for output
    func toDictionary() -> [String: Double] {
        return [
            "d12": d12,
            "d13": d13,
            "d14": d14,
            "d23": d23,
            "d24": d24,
            "d34": d34
        ]
    }
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
    let star1: StarInfo  // Original order (for reference)
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

    /// Convert to dictionary for output
    /// Output format:
    /// - descriptor: [x3, y3, x4, y4] - normalized coordinates of S3 and S4
    /// - s1_image, s2_image, s3_image, s4_image: [x, y] - image coordinates of each star
    func toDictionary() -> [String: Any] {
        return [
            "descriptor": [
                normalized.s3.x,
                normalized.s3.y,
                normalized.s4.x,
                normalized.s4.y
            ],
            "s1_image": [s1.x, s1.y],
            "s2_image": [s2.x, s2.y],
            "s3_image": [s3.x, s3.y],
            "s4_image": [s4.x, s4.y]
        ]
    }
}

/// Represents a seed star with its neighbors and generated quads
private struct SeedQuad {
    let seed: StarInfo
    let neighbors: [StarInfo]
    let quadLists: [Quad]
    let neighborCount: Int

    /// Convert to dictionary for output
    func toDictionary() -> [String: Any] {
        return [
            "seed": [
                "x": seed.x,
                "y": seed.y,
                "area": seed.area
            ],
            "neighbors": neighbors.map { neighbor in
                [
                    "x": neighbor.x,
                    "y": neighbor.y,
                    "area": neighbor.area
                ]
            },
            "quad_lists": quadLists.map { $0.toDictionary() },
            "neighbor_count": neighborCount
        ]
    }
}

// swiftlint:disable type_body_length
/// Pipeline step that creates quads from detected stars
public class QuadsStep: PipelineStep {
// swiftlint:enable type_body_length
    public let id: String = "quads"
    public let name: String = "Quads"
    public let description: String = "Creates quads from detected stars"

    public let requiredInputs: [String] = ["pixel_coordinates"]
    public let optionalInputs: [String] = ["max_stars", "min_distance_percent", "k_neighbors"]
    public let outputs: [String] = ["quads"]

    public init() {
    }

    public func execute(
        inputs: [String: PipelineStepInput],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [String: PipelineStepOutput] {
        let (componentTable, inputProcessedTable) = try getComponentTable(inputs: inputs)
        let components = try extractComponents(from: componentTable)
        let maxStars = Int(inputs["max_stars"]?.data.scalar ?? 50.0)
        let minDistancePercent = inputs["min_distance_percent"]?.data.scalar ?? 0.0
        let kNeighbors = Int(inputs["k_neighbors"]?.data.scalar ?? 5.0)

        // Get image dimensions for distance calculation
        let imageDimensions = try getImageDimensions(inputs: inputs)

        // Select brightest stars with minimum distance constraint
        let selectedComponents = selectBrightestStarsWithDistance(
            components: components,
            maxStars: maxStars,
            minDistancePercent: minDistancePercent,
            imageWidth: imageDimensions.width,
            imageHeight: imageDimensions.height
        )

        // Create quads using k-nearest neighbors
        let seedQuads = createQuadsFromNeighbors(
            selectedComponents: selectedComponents,
            kNeighbors: kNeighbors
        )

        let processedTable = createOutputTable(
            selectedComponents: selectedComponents,
            seedQuads: seedQuads,
            totalComponents: components.count,
            maxStars: maxStars,
            minDistancePercent: minDistancePercent,
            kNeighbors: kNeighbors,
            inputProcessedTable: inputProcessedTable
        )

        return [
            "quads": PipelineStepOutput(
                name: "quads",
                data: .processedTable(processedTable),
                description: "Top \(selectedComponents.count) brightest stars selected by area with minimum distance"
            )
        ]
    }

    // MARK: - Private Helper Methods

    private func getComponentTable(
        inputs: [String: PipelineStepInput]
    ) throws -> ([String: Any], ProcessedTable?) {
        guard let pixelCoordinatesInput = inputs["pixel_coordinates"] else {
            throw PipelineStepError.missingRequiredInput("pixel_coordinates")
        }

        if let processedTable = pixelCoordinatesInput.data.processedTable {
            return (processedTable.data, processedTable)
        } else if let table = pixelCoordinatesInput.data.table {
            return (table, nil)
        } else {
            throw PipelineStepError.invalidInputType("pixel_coordinates", expected: "processedTable or table")
        }
    }

    private func extractComponents(from componentTable: [String: Any]) throws -> [[String: Any]] {
        guard let components = componentTable["components"] as? [[String: Any]] else {
            throw PipelineStepError.executionFailed("Invalid component table format: missing 'components'")
        }
        return components
    }

    private func getImageDimensions(inputs: [String: PipelineStepInput]) throws -> (width: Int, height: Int) {
        // Try to get dimensions from input_image
        if let inputImageInput = inputs["input_image"] {
            if let processedImage = inputImageInput.data.processedImage {
                return (processedImage.width, processedImage.height)
            } else if let texture = inputImageInput.data.texture {
                return (texture.width, texture.height)
            } else if let fitsImage = inputImageInput.data.fitsImage {
                return (fitsImage.width, fitsImage.height)
            }
        }

        // Fallback: try to estimate from component coordinates
        // This is a last resort - we'll use a large default if we can't determine
        // The distance filtering will still work, just with estimated dimensions
        return (4096, 4096) // Default fallback dimensions
    }

    private func selectBrightestStars(
        components: [[String: Any]],
        maxStars: Int
    ) -> [[String: Any]] {
        let sortedComponents = components.sorted { component1, component2 -> Bool in
            let area1 = component1["area"] as? Int ?? 0
            let area2 = component2["area"] as? Int ?? 0
            return area1 > area2
        }
        return Array(sortedComponents.prefix(maxStars))
    }

    private func selectBrightestStarsWithDistance(
        components: [[String: Any]],
        maxStars: Int,
        minDistancePercent: Float,
        imageWidth: Int,
        imageHeight: Int
    ) -> [[String: Any]] {
        // If no minimum distance specified, just select brightest stars
        guard minDistancePercent > 0.0 else {
            return selectBrightestStars(components: components, maxStars: maxStars)
        }

        // Calculate minimum distance in pixels using Taxicab (Manhattan) distance
        // Taxicab diagonal = width + height (vs Euclidean = sqrt(width^2 + height^2))
        let imageDiagonal = Double(imageWidth + imageHeight)
        let minDistancePixels = imageDiagonal * Double(minDistancePercent) / 100.0

        // Sort by brightness (area)
        let sortedComponents = components.sorted { component1, component2 -> Bool in
            let area1 = component1["area"] as? Int ?? 0
            let area2 = component2["area"] as? Int ?? 0
            return area1 > area2
        }

        // Greedy selection using k-d tree for efficient distance checks
        // This is O(n log n) overall vs O(n²) for the linear approach
        var selected: [[String: Any]] = []
        var selectedPoints: [Point2D] = []
        let kdTree = KDTree()

        for component in sortedComponents {
            guard selected.count < maxStars else {
                break
            }

            // Get centroid
            guard let centroid = component["centroid"] as? [String: Any],
                  let centroidX = centroid["x"] as? Double,
                  let centroidY = centroid["y"] as? Double else {
                continue
            }

            let candidatePoint = Point2D(x: centroidX, y: centroidY)

            // Use k-d tree to check if any selected point is too close
            // This is O(log k) average case vs O(k) for linear search
            let hasNearbyPoint = kdTree.hasPointWithinDistance(
                from: candidatePoint,
                maxDistance: minDistancePixels
            )

            // If far enough from all selected stars, add to selection
            if !hasNearbyPoint {
                selected.append(component)
                selectedPoints.append(candidatePoint)

                // Rebuild k-d tree with new point
                // For small k (typically < 50), this is very fast
                kdTree.buildTree(points: selectedPoints)
            }
        }

        return selected
    }

    private func createQuadsFromNeighbors(
        selectedComponents: [[String: Any]],
        kNeighbors: Int
    ) -> [SeedQuad] {
        guard !selectedComponents.isEmpty, kNeighbors > 0 else {
            return []
        }

        // Extract points and create mapping from points to components
        var pointToComponent: [Point2D: [String: Any]] = [:]
        var points: [Point2D] = []

        for component in selectedComponents {
            guard let centroid = component["centroid"] as? [String: Any],
                  let centroidX = centroid["x"] as? Double,
                  let centroidY = centroid["y"] as? Double else {
                continue
            }

            let point = Point2D(x: centroidX, y: centroidY)
            pointToComponent[point] = component
            points.append(point)
        }

        // Build k-d tree from all selected points
        let kdTree = KDTree(points: points)

        // For each seed star, find its k nearest neighbors and create quad lists
        var seedQuads: [SeedQuad] = []

        for point in points {
            // Find k nearest neighbors (including the point itself)
            let neighbors = kdTree.kNearestNeighbors(to: point, k: min(kNeighbors + 1, points.count))

            // Filter out the point itself and get neighbor components
            let neighborPoints = neighbors.filter { $0 != point }
            let neighborComponents = neighborPoints.compactMap { pointToComponent[$0] }

            // Need at least 3 neighbors to form quads (seed + 3 neighbors = 4 stars)
            guard neighborComponents.count >= 3 else {
                continue
            }

            // Get seed star component
            guard let seedComponent = pointToComponent[point],
                  let seedStar = StarInfo(from: seedComponent, isSeed: true) else {
                continue
            }

            // Convert neighbor components to StarInfo
            let neighborStars = neighborPoints.prefix(kNeighbors).compactMap { neighborPoint -> StarInfo? in
                guard let neighborComponent = pointToComponent[neighborPoint] else {
                    return nil
                }
                return StarInfo(from: neighborComponent, isSeed: false)
            }

            // Generate all combinations of 3 neighbors to create quads
            let quadLists = generateQuadCombinations(
                seed: seedStar,
                neighbors: neighborStars
            )

            seedQuads.append(SeedQuad(
                seed: seedStar,
                neighbors: neighborStars,
                quadLists: quadLists,
                neighborCount: neighborComponents.count
            ))
        }

        // Deduplicate quads by canonical descriptor
        return deduplicateQuads(seedQuads: seedQuads)
    }

    /// Descriptor key for deduplication (using canonical coordinates)
    private struct DescriptorKey: Hashable {
        // swiftlint:disable identifier_name
        let x3: Double
        let y3: Double
        let x4: Double
        let y4: Double
        // swiftlint:enable identifier_name

        init(from quad: Quad) {
            self.x3 = quad.normalized.s3.x
            self.y3 = quad.normalized.s3.y
            self.x4 = quad.normalized.s4.x
            self.y4 = quad.normalized.s4.y
        }
    }

    /// Remove duplicate quads that have the same canonical descriptor
    private func deduplicateQuads(seedQuads: [SeedQuad]) -> [SeedQuad] {
        // Collect all quads with their descriptors
        var seenDescriptors: Set<DescriptorKey> = []
        var deduplicatedSeedQuads: [SeedQuad] = []

        for seedQuad in seedQuads {
            var deduplicatedQuads: [Quad] = []

            for quad in seedQuad.quadLists {
                let descriptorKey = DescriptorKey(from: quad)

                // Only keep quads with unique descriptors
                if !seenDescriptors.contains(descriptorKey) {
                    seenDescriptors.insert(descriptorKey)
                    deduplicatedQuads.append(quad)
                }
            }

            // Only include seed quads that still have quads after deduplication
            if !deduplicatedQuads.isEmpty {
                deduplicatedSeedQuads.append(SeedQuad(
                    seed: seedQuad.seed,
                    neighbors: seedQuad.neighbors,
                    quadLists: deduplicatedQuads,
                    neighborCount: seedQuad.neighborCount
                ))
            }
        }

        return deduplicatedSeedQuads
    }

    /// Generate all combinations of 4 stars: seed + 3 neighbors
    /// Returns a list of quads, where each quad is {seed, neighbor1, neighbor2, neighbor3}
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
    /// Returns distances: [d12, d13, d14, d23, d24, d34]
    /// where dij is the distance between star i and star j
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
    /// S1 is at (0, 0), S2 is at (1, 0), S3 and S4 are normalized relative to this baseline
    /// Returns normalized coordinates and the stars in normalized order (S1, S2, S3, S4)
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
        let maxPair = allDistances.max(by: { $0.distance < $1.distance })!

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
            // Stars remain in original order regardless of variant
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
        // Stars remain in original order regardless of variant
        // The descriptor is canonicalized for matching, but image coordinates stay the same
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
    /// Returns the canonical (lexicographically smallest) variant and which variant was chosen
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
        // V0: (x3, y3, x4, y4)
        // V1: (1-x3, -y3, 1-x4, -y4)
        // V2: (x3, -y3, x4, -y4)
        // V3: (1-x3, y3, 1-x4, y4)
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

    // swiftlint:disable function_parameter_count
    private func createOutputTable(
        selectedComponents: [[String: Any]],
        seedQuads: [SeedQuad],
        totalComponents: Int,
        maxStars: Int,
        minDistancePercent: Float,
        kNeighbors: Int,
        inputProcessedTable: ProcessedTable?
    ) -> ProcessedTable {
        // Convert seed quads to dictionaries for output
        let quadsDict = seedQuads.map { $0.toDictionary() }

        var quadsTableData: [String: Any] = [
            "components": selectedComponents,
            "component_count": selectedComponents.count,
            "quads": quadsDict,
            "quad_count": seedQuads.count,
            "total_components": totalComponents,
            "max_stars": maxStars,
            "k_neighbors": kNeighbors
        ]

        if minDistancePercent > 0.0 {
            quadsTableData["min_distance_percent"] = minDistancePercent
        }

        let baseProcessedTable = ProcessedTable(
            data: quadsTableData,
            processingHistory: inputProcessedTable?.processingHistory ?? [],
            name: "Selected Stars"
        )

        var parameters: [String: String] = [
            "max_stars": "\(maxStars)",
            "selected_count": "\(selectedComponents.count)",
            "quad_count": "\(seedQuads.count)",
            "k_neighbors": "\(kNeighbors)",
            "total_available": "\(totalComponents)"
        ]

        if minDistancePercent > 0.0 {
            parameters["min_distance_percent"] = String(format: "%.2f", minDistancePercent)
        }

        return baseProcessedTable.withProcessingStep(
            stepID: id,
            stepName: name,
            parameters: parameters,
            newData: quadsTableData,
            newName: "Selected Stars for Quads"
        )
    }
    // swiftlint:enable function_parameter_count
}
