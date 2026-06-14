import Testing
import Foundation
@testable import AstrophotoArchiveKit

@Suite("Pipeline result lineage (ASTR-57)")
struct LineageTests {

    // MARK: - DB-level

    @Test("supersedes_id is stored and retrieved")
    func supersedesIDRoundTrips() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let v1 = makeFrame()
        var v2 = makeFrame().withNewID()
        v2.supersedesID = v1.id

        _ = try await db.insertFrame(v1, deduplicate: false)
        _ = try await db.insertFrame(v2, deduplicate: false)

        let loaded = try await db.frameByID(v2.id)
        #expect(loaded?.supersedesID == v1.id)
    }

    @Test("supersedesID is nil for frames without a predecessor")
    func supersedesIDIsNilByDefault() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = makeFrame()
        _ = try await db.insertFrame(frame, deduplicate: false)

        let loaded = try await db.frameByID(frame.id)
        #expect(loaded?.supersedesID == nil)
    }

    @Test("successors() returns frames that point to a given frame")
    func successorsQuery() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let predecessor = makeFrame()
        var successor   = makeFrame().withNewID()
        let unrelated   = makeFrame().withNewID()
        successor.supersedesID = predecessor.id

        _ = try await db.insertFrame(predecessor, deduplicate: false)
        _ = try await db.insertFrame(successor,   deduplicate: false)
        _ = try await db.insertFrame(unrelated,   deduplicate: false)

        let found = try await db.successors(of: predecessor.id)
        #expect(found.count == 1)
        #expect(found.first?.id == successor.id)
    }

    @Test("updateFrameSupersedesID persists the link")
    func updateFrameSupersedesIDPersists() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let v1 = makeFrame()
        let v2 = makeFrame().withNewID()

        _ = try await db.insertFrame(v1, deduplicate: false)
        _ = try await db.insertFrame(v2, deduplicate: false)

        try await db.updateFrameSupersedesID(id: v2.id, supersedesID: v1.id)

        let loaded = try await db.frameByID(v2.id)
        #expect(loaded?.supersedesID == v1.id)
    }

    @Test("updateFrameSupersedesID with nil detaches the link")
    func updateFrameSupersedesIDClearsLink() async throws {
        let (db, url) = try makeTestDatabase()
        defer { try? FileManager.default.removeItem(at: url) }

        let v1 = makeFrame()
        var v2 = makeFrame().withNewID()
        v2.supersedesID = v1.id

        _ = try await db.insertFrame(v1, deduplicate: false)
        _ = try await db.insertFrame(v2, deduplicate: false)

        try await db.updateFrameSupersedesID(id: v2.id, supersedesID: nil)

        let loaded = try await db.frameByID(v2.id)
        #expect(loaded?.supersedesID == nil, "Passing nil must detach the lineage link")
    }

    // MARK: - Archive-level

    @Test("Archive.add stores supersedesID on the new record")
    func archiveAddStoresSupersedesID() async throws {
        let (archive, root) = try makeTempArchive(prefix: "lineage")
        defer { try? FileManager.default.removeItem(at: root) }

        let src1 = root.appendingPathComponent("v1.fits")
        let src2 = root.appendingPathComponent("v2.fits")
        try writeTinyFITS(to: src1, stacked: true)
        try writeTinyFITS(to: src2, stacked: true)

        let (v1, _) = try await archive.add(fitsFile: src1)
        let (v2, _) = try await archive.add(fitsFile: src2, supersedesID: v1.id)

        #expect(v2.supersedesID == v1.id)

        let reloaded = try await archive.frame(id: v2.id)
        #expect(reloaded?.supersedesID == v1.id)
    }

    @Test("Archive.lineage returns the full chain newest-to-oldest")
    func lineageChainIsOrdered() async throws {
        let (archive, root) = try makeTempArchive(prefix: "lineage-chain")
        defer { try? FileManager.default.removeItem(at: root) }

        let src1 = root.appendingPathComponent("v1.fits")
        let src2 = root.appendingPathComponent("v2.fits")
        let src3 = root.appendingPathComponent("v3.fits")
        try writeTinyFITS(to: src1, stacked: true)
        try writeTinyFITS(to: src2, stacked: true)
        try writeTinyFITS(to: src3, stacked: true)

        let (v1, _) = try await archive.add(fitsFile: src1)
        let (v2, _) = try await archive.add(fitsFile: src2, supersedesID: v1.id)
        let (v3, _) = try await archive.add(fitsFile: src3, supersedesID: v2.id)

        let chain = try await archive.lineage(of: v3)
        #expect(chain.count == 3)
        #expect(chain[0].id == v3.id)
        #expect(chain[1].id == v2.id)
        #expect(chain[2].id == v1.id)
    }

    @Test("Archive.lineage for a frame with no predecessors returns just that frame")
    func lineageSingleFrame() async throws {
        let (archive, root) = try makeTempArchive(prefix: "lineage-single")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("v1.fits")
        try writeTinyFITS(to: src, stacked: true)

        let (frame, _) = try await archive.add(fitsFile: src)
        let chain = try await archive.lineage(of: frame)
        #expect(chain.count == 1)
        #expect(chain[0].id == frame.id)
    }

    @Test("Archive.updateSupersedesID can set and clear the link")
    func archiveUpdateSupersedesID() async throws {
        let (archive, root) = try makeTempArchive(prefix: "lineage-update")
        defer { try? FileManager.default.removeItem(at: root) }

        let src1 = root.appendingPathComponent("v1.fits")
        let src2 = root.appendingPathComponent("v2.fits")
        try writeTinyFITS(to: src1, stacked: true)
        try writeTinyFITS(to: src2, stacked: true)

        let (v1, _) = try await archive.add(fitsFile: src1)
        let (v2, _) = try await archive.add(fitsFile: src2)
        #expect(v2.supersedesID == nil)

        // Set the link.
        try await archive.updateSupersedesID(frameID: v2.id, supersedesID: v1.id)
        #expect(try await archive.frame(id: v2.id)?.supersedesID == v1.id)

        // Clear the link.
        try await archive.updateSupersedesID(frameID: v2.id, supersedesID: nil)
        #expect(try await archive.frame(id: v2.id)?.supersedesID == nil)
    }

    @Test("Archive.successors returns the direct successor")
    func successorsReturnsDirectSuccessor() async throws {
        let (archive, root) = try makeTempArchive(prefix: "lineage-succ")
        defer { try? FileManager.default.removeItem(at: root) }

        let src1 = root.appendingPathComponent("v1.fits")
        let src2 = root.appendingPathComponent("v2.fits")
        try writeTinyFITS(to: src1, stacked: true)
        try writeTinyFITS(to: src2, stacked: true)

        let (v1, _) = try await archive.add(fitsFile: src1)
        let (v2, _) = try await archive.add(fitsFile: src2, supersedesID: v1.id)

        let successors = try await archive.successors(of: v1)
        #expect(successors.count == 1)
        #expect(successors.first?.id == v2.id)
    }

    // MARK: - fullLineage

    @Test("fullLineage from the newest frame returns only predecessors")
    func fullLineageFromNewest() async throws {
        let (archive, root) = try makeTempArchive(prefix: "full-newest")
        defer { try? FileManager.default.removeItem(at: root) }

        let (v1, v2, v3) = try await makeThreeVersionChain(archive: archive, root: root)

        let lineage = try await archive.fullLineage(containing: v3)
        #expect(lineage.count == 3)
        #expect(lineage.chain[0].id == v3.id)
        #expect(lineage.chain[1].id == v2.id)
        #expect(lineage.chain[2].id == v1.id)
        #expect(lineage.currentIndex == 0)
        #expect(lineage.currentVersionNumber == 3)
        #expect(lineage.current.id == v3.id)
    }

    @Test("fullLineage from the oldest frame walks forward to include all successors")
    func fullLineageFromOldest() async throws {
        let (archive, root) = try makeTempArchive(prefix: "full-oldest")
        defer { try? FileManager.default.removeItem(at: root) }

        let (v1, v2, v3) = try await makeThreeVersionChain(archive: archive, root: root)

        let lineage = try await archive.fullLineage(containing: v1)
        #expect(lineage.count == 3)
        #expect(lineage.chain[0].id == v3.id)
        #expect(lineage.chain[1].id == v2.id)
        #expect(lineage.chain[2].id == v1.id)
        #expect(lineage.currentIndex == 2)
        #expect(lineage.currentVersionNumber == 1)
        #expect(lineage.current.id == v1.id)
    }

    @Test("fullLineage from a middle frame includes both predecessors and successors")
    func fullLineageFromMiddle() async throws {
        let (archive, root) = try makeTempArchive(prefix: "full-middle")
        defer { try? FileManager.default.removeItem(at: root) }

        let (v1, v2, v3) = try await makeThreeVersionChain(archive: archive, root: root)

        let lineage = try await archive.fullLineage(containing: v2)
        #expect(lineage.count == 3)
        #expect(lineage.chain[0].id == v3.id)
        #expect(lineage.chain[1].id == v2.id)
        #expect(lineage.chain[2].id == v1.id)
        #expect(lineage.currentIndex == 1)
        #expect(lineage.currentVersionNumber == 2)
        #expect(lineage.current.id == v2.id)
    }

    @Test("fullLineage for an isolated frame returns a single-element chain")
    func fullLineageSingleFrame() async throws {
        let (archive, root) = try makeTempArchive(prefix: "full-single")
        defer { try? FileManager.default.removeItem(at: root) }

        let src = root.appendingPathComponent("only.fits")
        try writeTinyFITS(to: src, stacked: true)

        let (frame, _) = try await archive.add(fitsFile: src)
        let lineage = try await archive.fullLineage(containing: frame)

        #expect(lineage.count == 1)
        #expect(lineage.currentIndex == 0)
        #expect(lineage.currentVersionNumber == 1)
        #expect(lineage.current.id == frame.id)
    }

    @Test("fullLineage chain is identical regardless of which frame is queried")
    func fullLineageChainIsConsistentAcrossQueryFrames() async throws {
        let (archive, root) = try makeTempArchive(prefix: "full-consistent")
        defer { try? FileManager.default.removeItem(at: root) }

        let (v1, v2, v3) = try await makeThreeVersionChain(archive: archive, root: root)

        let fromV1 = try await archive.fullLineage(containing: v1)
        let fromV2 = try await archive.fullLineage(containing: v2)
        let fromV3 = try await archive.fullLineage(containing: v3)

        let ids1 = fromV1.chain.map(\.id)
        let ids2 = fromV2.chain.map(\.id)
        let ids3 = fromV3.chain.map(\.id)

        #expect(ids1 == ids2, "Chain from v1 and v2 must be identical")
        #expect(ids2 == ids3, "Chain from v2 and v3 must be identical")
    }
}

// MARK: - Helpers

private extension ArchivedFrame {
    func withNewID() -> ArchivedFrame {
        ArchivedFrame(
            id: UUID(),
            filePath: "/tmp/mock-\(UUID().uuidString).fits",
            objectName: objectName, ra: ra, dec: dec,
            healpixPixel: healpixPixel, frameType: frameType,
            filter: filter, camera: camera,
            focalLength: focalLength, pixelScale: pixelScale, temperature: temperature,
            timestamp: timestamp, exposureTime: exposureTime,
            gain: gain, offset: offset,
            width: width, height: height, bitpix: bitpix,
            calibrated: calibrated, stacked: stacked, stretched: stretched,
            processingLevel: processingLevel, addedAt: addedAt,
            processingRunID: processingRunID,
            supersedesID: supersedesID,
            fileDate: fileDate
        )
    }
}

private let referenceDate = Date(timeIntervalSince1970: 1_740_000_000)

private func makeFrame() -> ArchivedFrame {
    ArchivedFrame(
        id: UUID(),
        filePath: "/tmp/mock-\(UUID().uuidString).fits",
        objectName: "DWB 111",
        ra: 83.8221, dec: -5.3911,
        healpixPixel: nil,
        frameType: "light",
        filter: "Ha",
        camera: nil,
        focalLength: nil, pixelScale: nil, temperature: nil,
        timestamp: referenceDate,
        exposureTime: 300,
        gain: nil, offset: nil,
        width: 6248, height: 4176, bitpix: 16,
        calibrated: false, stacked: true, stretched: false,
        processingLevel: .stacked,
        addedAt: Date(),
        fileDate: referenceDate
    )
}

private func makeTestDatabase() throws -> (ArchiveDatabase, URL) {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("lineagetest-\(UUID().uuidString).sqlite")
    return (try ArchiveDatabase(url: url, archiveRootPath: FileManager.default.temporaryDirectory.path), url)
}

/// Creates a v1 → v2 → v3 chain in `archive`, using distinct DATE-OBS values so each
/// frame has a unique signature and is not deduplicated.
private func makeThreeVersionChain(archive: Archive, root: URL) async throws -> (ArchivedFrame, ArchivedFrame, ArchivedFrame) {
    let src1 = root.appendingPathComponent("chain-v1-\(UUID().uuidString).fits")
    let src2 = root.appendingPathComponent("chain-v2-\(UUID().uuidString).fits")
    let src3 = root.appendingPathComponent("chain-v3-\(UUID().uuidString).fits")
    try writeTinyFITS(to: src1, dateObs: "2025-06-01T10:00:00", stacked: true)
    try writeTinyFITS(to: src2, dateObs: "2025-06-01T11:00:00", stacked: true)
    try writeTinyFITS(to: src3, dateObs: "2025-06-01T12:00:00", stacked: true)

    let (v1, _) = try await archive.add(fitsFile: src1)
    let (v2, _) = try await archive.add(fitsFile: src2, supersedesID: v1.id)
    let (v3, _) = try await archive.add(fitsFile: src3, supersedesID: v2.id)
    return (v1, v2, v3)
}
