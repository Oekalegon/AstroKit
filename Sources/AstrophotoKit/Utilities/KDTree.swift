import Foundation

/// Represents a 2D point for use in a k-d tree
public struct Point2D: Equatable, Hashable {
    // swiftlint:disable identifier_name
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    // swiftlint:enable identifier_name

    /// Calculate Taxicab (Manhattan) distance to another point
    public func taxicabDistance(to other: Point2D) -> Double {
        return abs(x - other.x) + abs(y - other.y)
    }

    /// Calculate Euclidean distance to another point
    public func euclideanDistance(to other: Point2D) -> Double {
        let deltaX = x - other.x
        let deltaY = y - other.y
        return sqrt(deltaX * deltaX + deltaY * deltaY)
    }
}

/// A k-d tree node for 2D points
private class KDTreeNode {
    let point: Point2D
    let depth: Int
    var left: KDTreeNode?
    var right: KDTreeNode?

    init(point: Point2D, depth: Int) {
        self.point = point
        self.depth = depth
        self.left = nil
        self.right = nil
    }
}

/// A k-d tree for efficient spatial queries on 2D points
public class KDTree {
    private var root: KDTreeNode?
    private let dimension: Int = 2

    /// Initialize an empty k-d tree
    public init() {
        self.root = nil
    }

    /// Build a k-d tree from an array of points
    /// - Parameter points: Array of 2D points to insert into the tree
    public init(points: [Point2D]) {
        self.root = nil
        buildTree(points: points)
    }

    /// Build the k-d tree from an array of points
    /// - Parameter points: Array of 2D points to insert
    public func buildTree(points: [Point2D]) {
        guard !points.isEmpty else {
            root = nil
            return
        }
        root = buildTreeRecursive(points: points, depth: 0)
    }

    /// Recursively build the k-d tree
    private func buildTreeRecursive(points: [Point2D], depth: Int) -> KDTreeNode? {
        guard !points.isEmpty else {
            return nil
        }

        // Determine which axis to split on (alternate between x and y)
        let axis = depth % dimension

        // Sort points by the current axis
        let sortedPoints = points.sorted { point1, point2 in
            if axis == 0 {
                return point1.x < point2.x
            } else {
                return point1.y < point2.y
            }
        }

        // Find median point
        let medianIndex = sortedPoints.count / 2
        let medianPoint = sortedPoints[medianIndex]

        // Create node
        let node = KDTreeNode(point: medianPoint, depth: depth)

        // Recursively build left and right subtrees
        if medianIndex > 0 {
            let leftPoints = Array(sortedPoints[0..<medianIndex])
            node.left = buildTreeRecursive(points: leftPoints, depth: depth + 1)
        }

        if medianIndex + 1 < sortedPoints.count {
            let rightPoints = Array(sortedPoints[(medianIndex + 1)...])
            node.right = buildTreeRecursive(points: rightPoints, depth: depth + 1)
        }

        return node
    }

    // swiftlint:disable identifier_name
    /// Find k nearest neighbors to a given point
    /// - Parameters:
    ///   - point: The query point
    ///   - k: Number of nearest neighbors to find
    /// - Returns: Array of k nearest points, sorted by distance (closest first)
    ///            Returns fewer than k if the tree has fewer than k points
    public func kNearestNeighbors(to point: Point2D, k: Int) -> [Point2D] {
        guard let root = root, k > 0 else {
            return []
        }

        // Use a max-heap (priority queue) to maintain k nearest neighbors
        // We'll use an array and sort it, keeping only the k closest
        var neighbors: [(point: Point2D, distance: Double)] = []

        kNearestNeighborsRecursive(
            node: root,
            query: point,
            depth: 0,
            k: k,
            neighbors: &neighbors
        )

        // Sort by distance and return just the points
        return neighbors.sorted { $0.distance < $1.distance }.map { $0.point }
    }

    /// Recursively find k nearest neighbors
    private func kNearestNeighborsRecursive(
        node: KDTreeNode?,
        query: Point2D,
        depth: Int,
        k: Int,
        neighbors: inout [(point: Point2D, distance: Double)]
    ) {
        guard let node = node else {
            return
        }

        // Calculate distance to current node
        let distance = query.taxicabDistance(to: node.point)

        // Add to neighbors if we have fewer than k, or if this is closer than the farthest
        if neighbors.count < k {
            neighbors.append((point: node.point, distance: distance))
        } else {
            // Find the farthest neighbor
            let maxIndex = neighbors.enumerated().max(by: { $0.element.distance < $1.element.distance })?.offset ?? 0
            if distance < neighbors[maxIndex].distance {
                neighbors[maxIndex] = (point: node.point, distance: distance)
            }
        }

        // Determine which axis to compare
        let axis = depth % dimension
        let nodeValue = axis == 0 ? node.point.x : node.point.y
        let queryValue = axis == 0 ? query.x : query.y

        // Decide which subtree to search first
        let primaryChild: KDTreeNode?
        let secondaryChild: KDTreeNode?

        if queryValue < nodeValue {
            primaryChild = node.left
            secondaryChild = node.right
        } else {
            primaryChild = node.right
            secondaryChild = node.left
        }

        // Search primary subtree
        kNearestNeighborsRecursive(
            node: primaryChild,
            query: query,
            depth: depth + 1,
            k: k,
            neighbors: &neighbors
        )

        // Check if we need to search secondary subtree
        // We need to check if the hyperplane is closer than the farthest neighbor
        let axisDistance = abs(queryValue - nodeValue)
        let maxDistance = neighbors.count == k
            ? neighbors.max(by: { $0.distance < $1.distance })?.distance ?? Double.infinity
            : Double.infinity

        if axisDistance < maxDistance || neighbors.count < k {
            kNearestNeighborsRecursive(
                node: secondaryChild,
                query: query,
                depth: depth + 1,
                k: k,
                neighbors: &neighbors
            )
        }
    }
    // swiftlint:enable identifier_name

    /// Check if any point exists within a given distance
    /// - Parameters:
    ///   - point: The query point
    ///   - maxDistance: Maximum distance threshold
    /// - Returns: True if at least one point is within the distance threshold
    public func hasPointWithinDistance(
        from point: Point2D,
        maxDistance: Double
    ) -> Bool {
        guard let root = root else {
            return false
        }

        return hasPointWithinDistanceRecursive(
            node: root,
            query: point,
            maxDistance: maxDistance,
            depth: 0
        )
    }

    /// Recursively check if any point exists within distance
    private func hasPointWithinDistanceRecursive(
        node: KDTreeNode?,
        query: Point2D,
        maxDistance: Double,
        depth: Int
    ) -> Bool {
        guard let node = node else {
            return false
        }

        // Calculate distance to current node
        let distance = query.taxicabDistance(to: node.point)

        // Return true if within distance
        if distance <= maxDistance {
            return true
        }

        // Determine which axis to compare
        let axis = depth % dimension
        let nodeValue = axis == 0 ? node.point.x : node.point.y
        let queryValue = axis == 0 ? query.x : query.y

        // Decide which subtree to search
        let primaryChild: KDTreeNode?
        let secondaryChild: KDTreeNode?

        if queryValue < nodeValue {
            primaryChild = node.left
            secondaryChild = node.right
        } else {
            primaryChild = node.right
            secondaryChild = node.left
        }

        // Search primary subtree
        if hasPointWithinDistanceRecursive(
            node: primaryChild,
            query: query,
            maxDistance: maxDistance,
            depth: depth + 1
        ) {
            return true
        }

        // Check if we need to search secondary subtree
        let axisDistance = abs(queryValue - nodeValue)
        if axisDistance <= maxDistance {
            if hasPointWithinDistanceRecursive(
                node: secondaryChild,
                query: query,
                maxDistance: maxDistance,
                depth: depth + 1
            ) {
                return true
            }
        }

        return false
    }
}

