import Foundation
import Metal
import os

/// Structure to represent a 2D coordinate
public struct PixelCoordinate {
    // swiftlint:disable identifier_name
    public let x: Int
    public let y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
    // swiftlint:enable identifier_name
}

/// Structure to represent properties of a connected component
public struct ComponentProperties {
    public let area: Int
    public let centroidX: Double
    public let centroidY: Double
    public let majorAxis: Double
    public let minorAxis: Double
    public let eccentricity: Double
    public let rotationAngle: Double // in radians

    public init(
        area: Int,
        centroidX: Double,
        centroidY: Double,
        majorAxis: Double,
        minorAxis: Double,
        eccentricity: Double,
        rotationAngle: Double
    ) {
        self.area = area
        self.centroidX = centroidX
        self.centroidY = centroidY
        self.majorAxis = majorAxis
        self.minorAxis = minorAxis
        self.eccentricity = eccentricity
        self.rotationAngle = rotationAngle
    }
}

/// Pipeline step that finds connected components (groups of connected pixels) in a binary image
public class ConnectedComponentsStep: PipelineStep {
    public let id: String = "connected_components"
    public let name: String = "Connected Components"
    public let description: String = "Finds all connected components (groups of connected pixels) " +
        "in a binary image and returns their coordinates"

    public let requiredInputs: [String] = ["dilated_image"]
    public let optionalInputs: [String] = []
    public let outputs: [String] = ["pixel_coordinates", "coordinate_count"]

    public init() {
    }

    public func execute(
        inputs: [String: PipelineStepInput],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [String: PipelineStepOutput] {
        // Get input image (try dilated_image first, then fall back to other options)
        guard let inputImageInput = inputs["dilated_image"] ??
            inputs["eroded_image"] ??
            inputs["thresholded_image"] ??
            inputs["input_image"] else {
            throw PipelineStepError.missingRequiredInput(
                "dilated_image, eroded_image, thresholded_image, or input_image"
            )
        }

        // Get input texture
        let inputTexture: MTLTexture
        if let texture = inputImageInput.data.texture {
            inputTexture = texture
        } else if let fitsImage = inputImageInput.data.fitsImage {
            inputTexture = try fitsImage.createMetalTexture(device: device, pixelFormat: .r32Float)
        } else {
            throw PipelineStepError.invalidInputType("input_image", expected: "texture or fitsImage")
        }

        // First, get all non-zero pixel coordinates from GPU
        let collectStartTime = CFAbsoluteTimeGetCurrent()
        let allCoordinates = try collectNonZeroCoordinates(
            texture: inputTexture,
            device: device,
            commandQueue: commandQueue
        )
        let collectTime = CFAbsoluteTimeGetCurrent() - collectStartTime
        Logger.pipeline.debug("[ConnectedComponents] Coordinate collection: \(String(format: "%.3f", collectTime))s (\(allCoordinates.count) pixels)")

        // Then, find connected components from the coordinate list (CPU-based)
        let findStartTime = CFAbsoluteTimeGetCurrent()
        let components = findConnectedComponentsFromCoordinates(allCoordinates)
        let findTime = CFAbsoluteTimeGetCurrent() - findStartTime
        Logger.pipeline.debug("[ConnectedComponents] Component finding: \(String(format: "%.3f", findTime))s (\(components.count) components)")

        // Calculate properties for each component
        let calcStartTime = CFAbsoluteTimeGetCurrent()
        let componentProperties = components.map { component in
            calculateComponentProperties(component)
        }
        let calcTime = CFAbsoluteTimeGetCurrent() - calcStartTime
        Logger.pipeline.debug("[ConnectedComponents] Property calculation: \(String(format: "%.3f", calcTime))s")

        // Create table data for components with properties
        let componentTableData: [String: Any] = [
            "components": componentProperties.map { props in
                [
                    "area": props.area,
                    "centroid": ["x": props.centroidX, "y": props.centroidY],
                    "major_axis": props.majorAxis,
                    "minor_axis": props.minorAxis,
                    "eccentricity": props.eccentricity,
                    "rotation_angle": props.rotationAngle
                ]
            },
            "component_count": components.count,
            "total_pixels": components.reduce(0) { $0 + $1.count }
        ]
        
        // Get input ProcessedImage to inherit its processing history
        let inputProcessedImage: ProcessedImage?
        if let processedImage = inputImageInput.data.processedImage {
            inputProcessedImage = processedImage
        } else {
            inputProcessedImage = nil
        }
        
        // Create ProcessedTable with processing history
        // Start with empty history, then add this step
        let baseProcessedTable = ProcessedTable(
            data: componentTableData,
            processingHistory: inputProcessedImage?.processingHistory ?? [],
            name: "Component Properties"
        )
        
        let parameters: [String: String] = [
            "component_count": "\(components.count)",
            "total_pixels": "\(components.reduce(0) { $0 + $1.count })"
        ]
        
        let processedTable = baseProcessedTable.withProcessingStep(
            stepID: id,
            stepName: name,
            parameters: parameters,
            newData: componentTableData,
            newName: "Connected Components"
        )
        
        // Create ProcessedScalar with processing history from input image
        let baseProcessedScalar = ProcessedScalar(
            value: Float(components.count),
            processingHistory: inputProcessedImage?.processingHistory ?? [],
            name: "Coordinate Count"
        )
        
        let coordinateCountProcessedScalar = baseProcessedScalar.withProcessingStep(
            stepID: id,
            stepName: name,
            parameters: parameters,
            newValue: Float(components.count),
            newName: "Coordinate Count",
            newUnit: "components"
        )

        return [
            "pixel_coordinates": PipelineStepOutput(
                name: "pixel_coordinates",
                data: .processedTable(processedTable),
                description: "List of connected components with their properties " +
                    "(area, centroid, major/minor axis, eccentricity, rotation angle)"
            ),
            "coordinate_count": PipelineStepOutput(
                name: "coordinate_count",
                data: .processedScalar(coordinateCountProcessedScalar),
                description: "Number of connected components found"
            )
        ]
    }

    // MARK: - Private Helper Methods

    /// Collects all non-zero pixel coordinates from GPU
    private func collectNonZeroCoordinates(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [PixelCoordinate] {
        // Load shader library
        guard let library = AstrophotoKit.makeShaderLibrary(device: device) else {
            throw PipelineStepError.couldNotCreateResource("shader library")
        }

        guard let countFunction = library.makeFunction(name: "count_nonzero_pixels") else {
            throw PipelineStepError.couldNotCreateResource("count_nonzero_pixels function")
        }

        guard let collectFunction = library.makeFunction(name: "collect_nonzero_coordinates") else {
            throw PipelineStepError.couldNotCreateResource("collect_nonzero_coordinates function")
        }

        guard let countPipelineState = try? device.makeComputePipelineState(function: countFunction),
              let collectPipelineState = try? device.makeComputePipelineState(function: collectFunction) else {
            throw PipelineStepError.couldNotCreateResource("compute pipeline state")
        }

        // Pass 1: Count non-zero pixels
        let bufferSize = MemoryLayout<Int32>.size
        guard let countBuffer = device.makeBuffer(length: bufferSize, options: [.storageModeShared]) else {
            throw PipelineStepError.couldNotCreateResource("count buffer")
        }

        // Initialize count to zero
        let countPointer = countBuffer.contents().bindMemory(to: Int32.self, capacity: 1)
        countPointer[0] = 0

        guard let countCommandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }

        guard let countEncoder = countCommandBuffer.makeComputeCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("compute encoder")
        }

        countEncoder.setComputePipelineState(countPipelineState)
        countEncoder.setTexture(texture, index: 0)
        countEncoder.setBuffer(countBuffer, offset: 0, index: 0)

        let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadgroupsPerGrid = MTLSize(
            width: (texture.width + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (texture.height + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1
        )

        countEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        countEncoder.endEncoding()

        countCommandBuffer.commit()
        countCommandBuffer.waitUntilCompleted()

        if let error = countCommandBuffer.error {
            throw PipelineStepError.executionFailed("GPU count failed: \(error.localizedDescription)")
        }

        // Read count
        let pixelCount = Int(countPointer[0])

        guard pixelCount > 0 else {
            // No non-zero pixels found
            return []
        }

        // Pass 2: Collect coordinates
        // Create buffer for coordinates (each coordinate is 2 ints = 8 bytes)
        let coordinateBufferSize = pixelCount * MemoryLayout<Int32>.size * 2
        guard let coordinateBuffer = device.makeBuffer(
            length: coordinateBufferSize,
            options: [.storageModeShared]
        ) else {
            throw PipelineStepError.couldNotCreateResource("coordinate buffer")
        }

        // Create index buffer for atomic counter
        let indexBufferSize = MemoryLayout<Int32>.size
        guard let indexBuffer = device.makeBuffer(length: indexBufferSize, options: [.storageModeShared]) else {
            throw PipelineStepError.couldNotCreateResource("index buffer")
        }

        // Initialize index to zero
        let indexPointer = indexBuffer.contents().bindMemory(to: Int32.self, capacity: 1)
        indexPointer[0] = 0

        guard let collectCommandBuffer = commandQueue.makeCommandBuffer() else {
            throw PipelineStepError.couldNotCreateResource("command buffer")
        }

        guard let collectEncoder = collectCommandBuffer.makeComputeCommandEncoder() else {
            throw PipelineStepError.couldNotCreateResource("compute encoder")
        }

        collectEncoder.setComputePipelineState(collectPipelineState)
        collectEncoder.setTexture(texture, index: 0)
        collectEncoder.setBuffer(coordinateBuffer, offset: 0, index: 0)
        collectEncoder.setBuffer(indexBuffer, offset: 0, index: 1)

        collectEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        collectEncoder.endEncoding()

        collectCommandBuffer.commit()
        collectCommandBuffer.waitUntilCompleted()

        if let error = collectCommandBuffer.error {
            throw PipelineStepError.executionFailed("GPU coordinate collection failed: \(error.localizedDescription)")
        }

        // Read coordinates from buffer
        // The buffer contains Coordinate structs (2 ints each)
        let coordinatePointer = coordinateBuffer.contents().bindMemory(to: Int32.self, capacity: pixelCount * 2)
        var coordinates: [PixelCoordinate] = []
        coordinates.reserveCapacity(pixelCount)

        for index in 0..<pixelCount {
            let coordX = Int(coordinatePointer[index * 2])
            let coordY = Int(coordinatePointer[index * 2 + 1])
            coordinates.append(PixelCoordinate(x: coordX, y: coordY))
        }

        return coordinates
    }

    /// Finds connected components from a list of coordinates using CPU-based algorithm
    /// Uses 8-connectivity (pixels are connected if they are neighbors)
    /// Optimized version using a coordinate-to-index map for O(1) neighbor lookup
    private func findConnectedComponentsFromCoordinates(_ coordinates: [PixelCoordinate]) -> [[PixelCoordinate]] {
        guard !coordinates.isEmpty else {
            return []
        }

        // Create a coordinate-to-index map for O(1) neighbor lookup
        // Use a dictionary with (x, y) tuple as key for faster lookup than string concatenation
        var coordinateToIndex: [Int: Int] = [:]
        for (index, coord) in coordinates.enumerated() {
            // Use a hash of (x, y) for the key: x * large_prime + y
            // For images up to 100000x100000, we can use x * 1000000 + y
            let key = coord.x * 1_000_000 + coord.y
            coordinateToIndex[key] = index
        }

        // Union-Find data structure for connected components
        var parent: [Int] = Array(0..<coordinates.count)
        var rank: [Int] = Array(repeating: 0, count: coordinates.count)

        func find(_ index: Int) -> Int {
            if parent[index] != index {
                parent[index] = find(parent[index]) // Path compression
            }
            return parent[index]
        }

        func union(_ xIndex: Int, _ yIndex: Int) {
            let rootX = find(xIndex)
            let rootY = find(yIndex)

            if rootX == rootY {
                return
            }

            // Union by rank
            if rank[rootX] < rank[rootY] {
                parent[rootX] = rootY
            } else if rank[rootX] > rank[rootY] {
                parent[rootY] = rootX
            } else {
                parent[rootY] = rootX
                rank[rootX] += 1
            }
        }

        // Check 8-connectivity between all coordinate pairs
        for index in 0..<coordinates.count {
            let coord1 = coordinates[index]

            // Check 8 neighbors
            let neighbors = [
                (coord1.x - 1, coord1.y - 1), // top-left
                (coord1.x, coord1.y - 1),     // top
                (coord1.x + 1, coord1.y - 1), // top-right
                (coord1.x - 1, coord1.y),     // left
                (coord1.x + 1, coord1.y),     // right
                (coord1.x - 1, coord1.y + 1), // bottom-left
                (coord1.x, coord1.y + 1),     // bottom
                (coord1.x + 1, coord1.y + 1)  // bottom-right
            ]

            for (neighborX, neighborY) in neighbors {
                let neighborKey = neighborX * 1_000_000 + neighborY
                if let neighborIndex = coordinateToIndex[neighborKey] {
                    union(index, neighborIndex)
                }
            }
        }

        // Group coordinates by component
        var components: [Int: [PixelCoordinate]] = [:]
        for index in 0..<coordinates.count {
            let root = find(index)
            if components[root] == nil {
                components[root] = []
            }
            components[root]?.append(coordinates[index])
        }

        // Convert to array of arrays
        return Array(components.values)
    }

    /// Calculates image moments and derived properties for a connected component
    private func calculateComponentProperties(_ component: [PixelCoordinate]) -> ComponentProperties {
        guard !component.isEmpty else {
            return ComponentProperties(
                area: 0,
                centroidX: 0,
                centroidY: 0,
                majorAxis: 0,
                minorAxis: 0,
                eccentricity: 0,
                rotationAngle: 0
            )
        }

        // Calculate zeroth moment (area)
        let area = component.count
        let m00 = Double(area)

        // Calculate first moments (M10, M01) for centroid
        var m10: Double = 0
        var m01: Double = 0
        for coord in component {
            m10 += Double(coord.x)
            m01 += Double(coord.y)
        }

        // Centroid
        let centroidX = m10 / m00
        let centroidY = m01 / m00

        // Calculate second central moments (μ20, μ11, μ02)
        var mu20: Double = 0
        var mu11: Double = 0
        var mu02: Double = 0

        for coord in component {
            let deltaX = Double(coord.x) - centroidX
            let deltaY = Double(coord.y) - centroidY
            mu20 += deltaX * deltaX
            mu11 += deltaX * deltaY
            mu02 += deltaY * deltaY
        }

        // Normalize by area
        mu20 /= m00
        mu11 /= m00
        mu02 /= m00

        // Covariance matrix: [[μ20, μ11], [μ11, μ02]]
        // Calculate eigenvalues (major and minor axis lengths)
        // Eigenvalues of 2x2 matrix [[a, b], [c, d]]:
        // λ = (a+d)/2 ± sqrt((a-d)²/4 + bc)
        let trace = mu20 + mu02
        let determinant = mu20 * mu02 - mu11 * mu11
        let discriminant = trace * trace - 4 * determinant

        guard discriminant >= 0 else {
            // Should not happen for real covariance matrix, but handle gracefully
            return ComponentProperties(
                area: area,
                centroidX: centroidX,
                centroidY: centroidY,
                majorAxis: 0,
                minorAxis: 0,
                eccentricity: 0,
                rotationAngle: 0
            )
        }

        let sqrtDiscriminant = sqrt(discriminant)
        let lambda1 = (trace + sqrtDiscriminant) / 2.0
        let lambda2 = (trace - sqrtDiscriminant) / 2.0

        // Major axis is larger eigenvalue, minor axis is smaller
        let majorLambda = max(lambda1, lambda2)
        let minorLambda = min(lambda1, lambda2)
        let majorAxis = sqrt(majorLambda) * 4.0 // Multiply by 4 for pixel scale
        let minorAxis = sqrt(minorLambda) * 4.0

        // Eccentricity: e = sqrt(1 - (b/a)²) where a is major axis, b is minor axis
        let eccentricity: Double
        if majorAxis > 0 {
            let ratio = minorAxis / majorAxis
            eccentricity = sqrt(max(0, 1.0 - ratio * ratio))
        } else {
            eccentricity = 0
        }

        // Rotation angle: θ = 0.5 * atan2(2*μ11, μ20-μ02)
        let rotationAngle = 0.5 * atan2(2.0 * mu11, mu20 - mu02)

        return ComponentProperties(
            area: area,
            centroidX: centroidX,
            centroidY: centroidY,
            majorAxis: majorAxis,
            minorAxis: minorAxis,
            eccentricity: eccentricity,
            rotationAngle: rotationAngle
        )
    }
}
