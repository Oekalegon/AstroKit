import Foundation
import Metal
import TabularData
import os

/// Structure to represent a 2D coordinate
private struct PixelCoordinate {
    // swiftlint:disable identifier_name
    let x: Int
    let y: Int
    // swiftlint:enable identifier_name
}

/// Structure to represent properties of a connected component
private struct ComponentProperties {
    let area: Int
    let centroidX: Double
    let centroidY: Double
    let majorAxis: Double
    let minorAxis: Double
    let eccentricity: Double
    let rotationAngle: Double // in radians
}

/// Processor for finding connected components in a binary image
public struct ConnectedComponentsProcessor: Processor {

    public var id: String { "connected_components" }

    public init() {}

    /// Execute the connected components processor
    /// - Parameters:
    ///   - inputs: Dictionary containing "input_frame" -> ProcessData (Frame)
    ///   - outputs: Dictionary containing "pixel_coordinates" -> ProcessData (TableData, to be instantiated)
    ///   - parameters: Dictionary (empty for this processor)
    ///   - device: Metal device for GPU operations
    ///   - commandQueue: Metal command queue for GPU operations
    /// - Throws: ProcessorExecutionError if execution fails
    public func execute(
        inputs: [String: ProcessData],
        outputs: inout [String: ProcessData],
        parameters: [String: Parameter],
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws {
        // Validate input frame
        let (_, inputTexture) = try ProcessorHelpers.validateInputFrame(from: inputs)

        Logger.processor.debug(
            "Finding connected components (width: \(inputTexture.width), height: \(inputTexture.height))"
        )

        // Step 1: Collect non-zero pixel coordinates from GPU
        let allCoordinates = try collectNonZeroCoordinates(
            texture: inputTexture,
            device: device,
            commandQueue: commandQueue
        )

        Logger.processor.debug("Collected \(allCoordinates.count) non-zero pixels")

        guard !allCoordinates.isEmpty else {
            // No pixels found, create empty table
            if var outputTable = outputs["pixel_coordinates"] as? TableData {
                var dataFrame = DataFrame()
                dataFrame.append(column: Column(name: "area", contents: [] as [Int]))
                dataFrame.append(column: Column(name: "centroid_x", contents: [] as [Double]))
                dataFrame.append(column: Column(name: "centroid_y", contents: [] as [Double]))
                dataFrame.append(column: Column(name: "major_axis", contents: [] as [Double]))
                dataFrame.append(column: Column(name: "minor_axis", contents: [] as [Double]))
                dataFrame.append(column: Column(name: "eccentricity", contents: [] as [Double]))
                dataFrame.append(column: Column(name: "rotation_angle", contents: [] as [Double]))
                outputTable.dataFrame = dataFrame
                outputs["pixel_coordinates"] = outputTable
            }
            return
        }

        // Step 2: Find connected components from coordinates (CPU-based)
        let components = findConnectedComponentsFromCoordinates(allCoordinates)

        Logger.processor.debug("Found \(components.count) connected components")

        // Step 3: Calculate properties for each component
        let componentProperties = components.map { component in
            calculateComponentProperties(component)
        }

        // Step 4: Create DataFrame with component properties
        // Sort by area (descending) so largest stars appear first
        let sortedProperties = componentProperties.sorted { $0.area > $1.area }
        
        if var outputTable = outputs["pixel_coordinates"] as? TableData {
            var dataFrame = DataFrame()
            // Add ID column (sequence number starting from 0)
            dataFrame.append(column: Column(name: "id", contents: Array(0..<sortedProperties.count)))
            dataFrame.append(column: Column(name: "area", contents: sortedProperties.map { $0.area }))
            dataFrame.append(column: Column(name: "centroid_x", contents: sortedProperties.map { $0.centroidX }))
            dataFrame.append(column: Column(name: "centroid_y", contents: sortedProperties.map { $0.centroidY }))
            dataFrame.append(
                column: Column(name: "major_axis", contents: sortedProperties.map { $0.majorAxis })
            )
            dataFrame.append(
                column: Column(name: "minor_axis", contents: sortedProperties.map { $0.minorAxis })
            )
            dataFrame.append(column: Column(name: "eccentricity", contents: sortedProperties.map { $0.eccentricity }))
            dataFrame.append(column: Column(name: "rotation_angle", contents: sortedProperties.map { $0.rotationAngle }))
            outputTable.dataFrame = dataFrame
            outputs["pixel_coordinates"] = outputTable
        }

        Logger.processor.info("Connected components analysis completed (\(components.count) components)")
    }

    // MARK: - Private Helper Methods

    /// Collects all non-zero pixel coordinates from GPU
    private func collectNonZeroCoordinates(
        texture: MTLTexture,
        device: MTLDevice,
        commandQueue: MTLCommandQueue
    ) throws -> [PixelCoordinate] {
        // Load shader library
        let library = try ProcessorHelpers.loadShaderLibrary(device: device)

        guard let countFunction = library.makeFunction(name: "count_nonzero_pixels"),
              let collectFunction = library.makeFunction(name: "collect_nonzero_coordinates") else {
            throw ProcessorExecutionError.couldNotCreateResource(
                "Could not load connected components shader functions"
            )
        }

        // Create compute pipeline states
        let countPipelineState = try ProcessorHelpers.createComputePipelineState(
            function: countFunction,
            device: device
        )
        let collectPipelineState = try ProcessorHelpers.createComputePipelineState(
            function: collectFunction,
            device: device
        )

        // Pass 1: Count non-zero pixels
        let countBuffer = device.makeBuffer(length: MemoryLayout<Int32>.size, options: [.storageModeShared])
        guard let countBuffer = countBuffer else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create count buffer")
        }

        // Initialize count to zero
        let countPointer = countBuffer.contents().bindMemory(to: Int32.self, capacity: 1)
        countPointer[0] = 0

        let countCommandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let countEncoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: countCommandBuffer)

        countEncoder.setComputePipelineState(countPipelineState)
        countEncoder.setTexture(texture, index: 0)
        countEncoder.setBuffer(countBuffer, offset: 0, index: 0)

        let (threadgroupSize, threadgroupsPerGrid) = ProcessorHelpers.calculateThreadgroups(for: texture)
        countEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        countEncoder.endEncoding()

        try ProcessorHelpers.executeCommandBuffer(countCommandBuffer)

        // Read count
        let pixelCount = Int(countPointer[0])

        guard pixelCount > 0 else {
            return []
        }

        // Pass 2: Collect coordinates
        // Create buffer for coordinates (each coordinate is 2 ints = 8 bytes)
        let coordinateBufferSize = pixelCount * MemoryLayout<Int32>.size * 2
        guard let coordinateBuffer = device.makeBuffer(
            length: coordinateBufferSize,
            options: [.storageModeShared]
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create coordinate buffer")
        }

        // Create index buffer for atomic counter
        guard let indexBuffer = device.makeBuffer(
            length: MemoryLayout<Int32>.size,
            options: [.storageModeShared]
        ) else {
            throw ProcessorExecutionError.couldNotCreateResource("Could not create index buffer")
        }

        // Initialize index to zero
        let indexPointer = indexBuffer.contents().bindMemory(to: Int32.self, capacity: 1)
        indexPointer[0] = 0

        let collectCommandBuffer = try ProcessorHelpers.createCommandBuffer(commandQueue: commandQueue)
        let collectEncoder = try ProcessorHelpers.createComputeEncoder(commandBuffer: collectCommandBuffer)

        collectEncoder.setComputePipelineState(collectPipelineState)
        collectEncoder.setTexture(texture, index: 0)
        collectEncoder.setBuffer(coordinateBuffer, offset: 0, index: 0)
        collectEncoder.setBuffer(indexBuffer, offset: 0, index: 1)

        collectEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadgroupSize)
        collectEncoder.endEncoding()

        try ProcessorHelpers.executeCommandBuffer(collectCommandBuffer)

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
    private func findConnectedComponentsFromCoordinates(_ coordinates: [PixelCoordinate]) -> [[PixelCoordinate]] {
        guard !coordinates.isEmpty else {
            return []
        }

        // Create a coordinate-to-index map for O(1) neighbor lookup
        var coordinateToIndex: [Int: Int] = [:]
        for (index, coord) in coordinates.enumerated() {
            // Use a hash of (x, y) for the key: x * large_prime + y
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


