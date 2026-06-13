import Testing
import Foundation
@testable import AstrophotoArchiveKit

@Suite("FrameSet add/remove members (ASTR-39)")
struct FrameSetAddRemoveTests {

    /// Creates an Archive plus a second database connection onto the same file,
    /// so tests can insert frames directly (same pattern as FrameSetTests).
    private func makeArchive() throws -> (Archive, ArchiveDatabase, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-\(UUID().uuidString)")
        let config = ArchiveConfiguration(rootURL: root)
        let archive = try Archive(configuration: config)
        let db = try ArchiveDatabase(
            url: root.appendingPathComponent("archive.db"),
            archiveRootPath: root.path
        )
        return (archive, db, root)
    }

    private func makeFrame(
        frameType: String = "light",
        filter: String? = "Hɑ",
        objectName: String? = "M42",
        camera: String? = "ZWO ASI294MC",
        exposureTime: Double = 300,
        temperature: Double? = -10.0,
        gain: Double? = 100,
        timestamp: Double = 1_740_000_000,
        processingLevel: ProcessingLevel = .raw
    ) -> ArchivedFrame {
        let date = Date(timeIntervalSince1970: timestamp)
        return ArchivedFrame(
            id: UUID(),
            filePath: "/tmp/mock-\(UUID().uuidString).fits",
            objectName: objectName,
            ra: 83.8221, dec: -5.3911,
            healpixPixel: nil,
            frameType: frameType,
            filter: filter,
            camera: camera,
            focalLength: nil, pixelScale: nil,
            temperature: temperature,
            timestamp: date,
            exposureTime: exposureTime,
            gain: gain, offset: nil,
            width: 4096, height: 2160, bitpix: 16,
            calibrated: processingLevel == .calibrated,
            stacked: processingLevel == .stacked,
            stretched: processingLevel == .stretched,
            processingLevel: processingLevel,
            addedAt: Date(),
            fileDate: date
        )
    }

    private func makeSet(
        _ archive: Archive, _ db: ArchiveDatabase,
        frameCount: Int = 2,
        objectName: String = "M42",
        filter: String = "Hɑ",
        maxFWHM: Double? = nil
    ) async throws -> (ArchivedFrameSet, [ArchivedFrame]) {
        var frames: [ArchivedFrame] = []
        for i in 0..<frameCount {
            let f = makeFrame(filter: filter, objectName: objectName,
                              timestamp: 1_740_000_000 + Double(i) * 1000)
            _ = try await db.insertFrame(f)
            frames.append(f)
        }
        var query = FrameQuery()
        query.objectName = objectName
        query.frameTypes = ["light"]
        query.filters = [filter]
        let (fs, _) = try await archive.createFrameSet(
            name: "test set", query: query, maxFWHM: maxFWHM
        )
        return (fs, frames)
    }

    // MARK: - Criteria persistence

    @Test func criteriaArePersistedOnCreation() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, _) = try await makeSet(archive, db, maxFWHM: 4.5)

        let reloaded = try await archive.frameSet(id: fs.id)
        let criteria = try #require(reloaded?.criteria)
        #expect(criteria.query.objectName == "M42")
        #expect(criteria.query.frameTypes == ["light"])
        #expect(criteria.query.filters == ["Hɑ"])
        #expect(criteria.maxFWHM == 4.5)
        // Thresholds are stored separately, stripped from the query itself.
        #expect(criteria.query.maxFWHM == nil)
    }

    // MARK: - Adding frames

    @Test func addFrameAppendsAndRefreshesAggregates() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, frames) = try await makeSet(archive, db)
        let newFrame = makeFrame(timestamp: 1_740_010_000)
        _ = try await db.insertFrame(newFrame)

        let result = try await archive.addFrames(toFrameSet: fs.id, frameIDs: [newFrame.id])
        #expect(result.addedIDs == [newFrame.id])
        #expect(result.alreadyMemberIDs.isEmpty)
        #expect(result.frameSet.frameCount == 3)
        // New member is appended after the original members (whose stored order
        // follows the creation query result, not insertion order).
        let ids = try await db.frameIDsForSet(fs.id)
        #expect(Set(ids.dropLast()) == Set(frames.map { $0.id }))
        #expect(ids.last == newFrame.id)
        // The date span must now extend to the new frame's timestamp.
        #expect(result.frameSet.dateTo == newFrame.timestamp)
    }

    @Test func addFrameSkipsExistingMembers() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, frames) = try await makeSet(archive, db)
        let result = try await archive.addFrames(toFrameSet: fs.id, frameIDs: [frames[0].id])
        #expect(result.addedIDs.isEmpty)
        #expect(result.alreadyMemberIDs == [frames[0].id])
        #expect(result.frameSet.frameCount == 2)
    }

    @Test func addFrameRejectsWrongFrameType() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, _) = try await makeSet(archive, db)
        let dark = makeFrame(frameType: "dark", filter: nil, objectName: nil, timestamp: 1_740_010_000)
        _ = try await db.insertFrame(dark)

        await #expect(throws: ArchiveError.self) {
            try await archive.addFrames(toFrameSet: fs.id, frameIDs: [dark.id])
        }
        // Even --force must not override the frame type invariant.
        await #expect(throws: ArchiveError.self) {
            try await archive.addFrames(toFrameSet: fs.id, frameIDs: [dark.id], force: true)
        }
    }

    @Test func addFrameRejectsWrongProcessingLevel() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, _) = try await makeSet(archive, db)
        let calibrated = makeFrame(timestamp: 1_740_010_000, processingLevel: .calibrated)
        _ = try await db.insertFrame(calibrated)

        await #expect(throws: ArchiveError.self) {
            try await archive.addFrames(toFrameSet: fs.id, frameIDs: [calibrated.id], force: true)
        }
    }

    @Test func addFrameRejectsDifferentFilterUnlessForced() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, _) = try await makeSet(archive, db)
        let oiii = makeFrame(filter: "OIII", timestamp: 1_740_010_000)
        _ = try await db.insertFrame(oiii)

        await #expect(throws: ArchiveError.self) {
            try await archive.addFrames(toFrameSet: fs.id, frameIDs: [oiii.id])
        }

        // With force the frame is accepted and the set's filter becomes a list.
        let result = try await archive.addFrames(toFrameSet: fs.id, frameIDs: [oiii.id], force: true)
        #expect(result.addedIDs == [oiii.id])
        #expect(result.frameSet.filter == "Hɑ,OIII")
    }

    @Test func addFrameOutsideDateRangeIsAllowedWithoutForce() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        // Set created with a narrow date window; candidate was captured after it.
        let t0 = Date(timeIntervalSince1970: 1_740_000_000)
        let t1 = Date(timeIntervalSince1970: 1_740_001_000)
        var q = FrameQuery()
        q.objectName = "M42"
        q.frameTypes = ["light"]
        q.filters = ["Hɑ"]
        q.dateRange = DateInterval(start: t0, end: t1)

        let f1 = makeFrame(timestamp: 1_740_000_500)
        _ = try await db.insertFrame(f1)
        let (fs, _) = try await archive.createFrameSet(name: "dated set", query: q)
        #expect(fs.criteria?.query.dateRange != nil)

        let later = makeFrame(timestamp: 1_740_100_000)
        _ = try await db.insertFrame(later)

        // Must succeed without --force, because dateRange is not a membership invariant.
        let result = try await archive.addFrames(toFrameSet: fs.id, frameIDs: [later.id])
        #expect(result.addedIDs == [later.id])
    }

    @Test func addFrameRejectsCriteriaMismatchUnlessForced() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        // Set created with object M42; candidate frame is the same type/filter but M31.
        let (fs, _) = try await makeSet(archive, db, objectName: "M42")
        let other = makeFrame(objectName: "M31", timestamp: 1_740_010_000)
        _ = try await db.insertFrame(other)

        await #expect(throws: ArchiveError.self) {
            try await archive.addFrames(toFrameSet: fs.id, frameIDs: [other.id])
        }

        let result = try await archive.addFrames(toFrameSet: fs.id, frameIDs: [other.id], force: true)
        #expect(result.addedIDs == [other.id])
        // Shared object name no longer agrees, so the aggregate becomes nil.
        #expect(result.frameSet.objectName == nil)
    }

    @Test func addFrameRejectsRejectedFrames() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, _) = try await makeSet(archive, db)
        let bad = makeFrame(timestamp: 1_740_010_000)
        _ = try await db.insertFrame(bad)
        try await archive.reject(id: bad.id, reason: "clouds")

        await #expect(throws: ArchiveError.self) {
            try await archive.addFrames(toFrameSet: fs.id, frameIDs: [bad.id])
        }
    }

    @Test func addFrameThrowsForUnknownSetAndFrame() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        await #expect(throws: ArchiveError.self) {
            try await archive.addFrames(toFrameSet: UUID(), frameIDs: [UUID()])
        }

        let (fs, _) = try await makeSet(archive, db)
        await #expect(throws: ArchiveError.self) {
            try await archive.addFrames(toFrameSet: fs.id, frameIDs: [UUID()])
        }
    }

    @Test func addFrameExceedingQualityThresholdIsMarkedExcluded() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, _) = try await makeSet(archive, db, maxFWHM: 4.0)
        let blurry = makeFrame(timestamp: 1_740_010_000)
        _ = try await db.insertFrame(blurry)
        try await archive.updateFrameQuality(id: blurry.id, medianFWHM: 7.5)

        let result = try await archive.addFrames(toFrameSet: fs.id, frameIDs: [blurry.id])
        #expect(result.addedIDs == [blurry.id])
        #expect(result.excludedReasons[blurry.id]?.contains("FWHM") == true)
        #expect(result.frameSet.frameCount == 3)
        #expect(result.frameSet.excludedFrameCount == 1)

        let activeIDs = try await db.frameIDsForSet(fs.id, activeOnly: true)
        #expect(!activeIDs.contains(blurry.id))
    }

    // MARK: - Removing frames

    @Test func removeFrameUpdatesMembershipAndAggregates() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, frames) = try await makeSet(archive, db, frameCount: 3)
        let result = try await archive.removeFrames(fromFrameSet: fs.id, frameIDs: [frames[2].id])

        #expect(result.removedIDs == [frames[2].id])
        #expect(result.notMemberIDs.isEmpty)
        #expect(result.frameSet.frameCount == 2)
        // Date span shrinks back to the remaining members.
        #expect(result.frameSet.dateTo == frames[1].timestamp)

        let ids = try await db.frameIDsForSet(fs.id)
        #expect(Set(ids) == Set([frames[0].id, frames[1].id]))

        // The removed frame itself must remain in the archive.
        let stillThere = try await db.frameByID(frames[2].id)
        #expect(stillThere != nil)
    }

    @Test func removeFrameSkipsNonMembers() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, _) = try await makeSet(archive, db)
        let outsider = makeFrame(timestamp: 1_740_010_000)
        _ = try await db.insertFrame(outsider)

        let result = try await archive.removeFrames(fromFrameSet: fs.id, frameIDs: [outsider.id])
        #expect(result.removedIDs.isEmpty)
        #expect(result.notMemberIDs == [outsider.id])
        #expect(result.frameSet.frameCount == 2)
    }

    @Test func removeRefusesToEmptyTheSet() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, frames) = try await makeSet(archive, db, frameCount: 2)
        await #expect(throws: ArchiveError.self) {
            try await archive.removeFrames(fromFrameSet: fs.id, frameIDs: frames.map { $0.id })
        }
        // Nothing was removed.
        let ids = try await db.frameIDsForSet(fs.id)
        #expect(ids.count == 2)
    }

    @Test func addAfterRemoveReassignsPositionsWithoutCollision() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        let (fs, frames) = try await makeSet(archive, db, frameCount: 3)
        _ = try await archive.removeFrames(fromFrameSet: fs.id, frameIDs: [frames[1].id])

        let newFrame = makeFrame(timestamp: 1_740_010_000)
        _ = try await db.insertFrame(newFrame)
        _ = try await archive.addFrames(toFrameSet: fs.id, frameIDs: [newFrame.id])

        let ids = try await db.frameIDsForSet(fs.id)
        #expect(Set(ids.dropLast()) == Set([frames[0].id, frames[2].id]))
        #expect(ids.last == newFrame.id)
    }

    // MARK: - Legacy sets without criteria

    @Test func addToLegacySetWithoutCriteriaChecksInvariantsOnly() async throws {
        let (archive, db, root) = try makeArchive()
        defer { try? FileManager.default.removeItem(at: root) }

        // Simulate a pre-v27 set: inserted directly without criteria.
        let f1 = makeFrame(timestamp: 1_740_000_000)
        _ = try await db.insertFrame(f1)
        let fs = ArchivedFrameSet(
            id: UUID(), name: "legacy", frameType: "light", processingLevel: .raw,
            createdAt: Date(), frameCount: 1,
            objectName: "M42", filter: "Hɑ", camera: nil,
            exposureTime: nil, gain: nil, offset: nil,
            width: nil, height: nil,
            pixelScale: nil, focalLength: nil, positionAngle: nil,
            dateFrom: nil, dateTo: nil,
            temperatureMean: nil, temperatureMin: nil, temperatureMax: nil
        )
        try await db.insertFrameSet(fs, frameIDs: [f1.id])

        // Same type/level/filter: accepted even though there is no stored query.
        let f2 = makeFrame(timestamp: 1_740_001_000)
        _ = try await db.insertFrame(f2)
        let result = try await archive.addFrames(toFrameSet: fs.id, frameIDs: [f2.id])
        #expect(result.addedIDs == [f2.id])

        // Different filter still gets blocked by the invariant check.
        let oiii = makeFrame(filter: "OIII", timestamp: 1_740_002_000)
        _ = try await db.insertFrame(oiii)
        await #expect(throws: ArchiveError.self) {
            try await archive.addFrames(toFrameSet: fs.id, frameIDs: [oiii.id])
        }
    }
}
