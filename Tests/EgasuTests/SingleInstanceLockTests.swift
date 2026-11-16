import XCTest
@testable import Egasu

@MainActor
final class SingleInstanceLockTests: XCTestCase {
    func testNewVersionHonorsTheLegacyBundleLock() throws {
        let bundleID = "EgasuTests.SingleInstance.\(UUID().uuidString)"
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("egasu-lock-path-\(UUID().uuidString)", isDirectory: true)
        let legacyURL = appSupport.appendingPathComponent("OpenUsage/\(bundleID).lock")
        let renamedURL = appSupport.appendingPathComponent("\(StorageNamespace.current.name)/\(bundleID).lock")
        defer { try? FileManager.default.removeItem(at: appSupport) }
        guard case .acquired(let legacyToken) = SingleInstanceLock.acquire(at: legacyURL) else {
            return XCTFail("legacy version should acquire its bundle lock")
        }
        withExtendedLifetime(legacyToken) {
            assertAlreadyRunning(
                SingleInstanceLock.acquire(bundleIdentifier: bundleID, applicationSupportRoot: appSupport))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamedURL.path))
    }

    func testSecondAcquisitionIsRejectedUntilTheFirstTokenIsReleased() throws {
        let lockURL = makeLockURL()
        var token: SingleInstanceLock.Token?

        switch SingleInstanceLock.acquire(at: lockURL) {
        case .acquired(let acquired):
            token = acquired
        default:
            XCTFail("first acquisition should own the lock")
        }

        XCTAssertNotNil(token)
        assertAlreadyRunning(SingleInstanceLock.acquire(at: lockURL))
        token = nil

        switch SingleInstanceLock.acquire(at: lockURL) {
        case .acquired:
            break
        default:
            XCTFail("lock should be acquirable after the first token is released")
        }
    }

    func testLockRejectsDuplicateWhenRunningApplicationSnapshotMissesThePeer() throws {
        let lockURL = makeLockURL()
        var token: SingleInstanceLock.Token?

        switch SingleInstanceLock.acquire(at: lockURL) {
        case .acquired(let acquired):
            token = acquired
        default:
            XCTFail("first acquisition should own the lock")
        }

        XCTAssertNotNil(token)
        XCTAssertNil(SingleInstanceGuard.instanceToYieldTo(myPID: 101, runningPIDs: [101]))
        assertAlreadyRunning(SingleInstanceLock.acquire(at: lockURL))
        token = nil
    }

    private func makeLockURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("egasu-lock-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("egasu.lock")
    }

    private func assertAlreadyRunning(
        _ acquisition: SingleInstanceLock.Acquisition,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .alreadyRunning = acquisition else {
            XCTFail("second acquisition should be rejected", file: file, line: line)
            return
        }
    }
}
