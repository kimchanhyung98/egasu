import Darwin
import Foundation
import XCTest
@testable import Egasu

final class ProcessTerminationControllerTests: XCTestCase {
    func testNaturalExitRecordsZombieOnlyGroupObservation() throws {
        let logs = try captureLogs {
            try withExitedLeader { leader in
                let controller = ProcessTerminationController {}
                controller.didLaunch(processGroupID: leader)
                controller.didCompleteNaturally()
            }
        }

        XCTAssertTrue(logs.contains("No live command process group members observed after cleanup"), logs)
        XCTAssertFalse(logs.contains("Failed to terminate command process group"), logs)
    }

    func testCancellationAfterExitRecordsZombieOnlyGroupObservation() throws {
        let logs = try captureLogs {
            try withExitedLeader { leader in
                let controller = ProcessTerminationController {}
                controller.didLaunch(processGroupID: leader)
                controller.requestTermination()
            }
        }

        XCTAssertTrue(logs.contains("No live command process group members observed after cleanup"), logs)
        XCTAssertFalse(logs.contains("Failed to terminate command process group"), logs)
    }

    func testPermissionFailureWithALiveProcessGroupRemainsAnError() throws {
        let logs = try captureLogs {
            let leader = try StreamingProcessRunner.spawn(
                executable: "/bin/sleep", arguments: ["30"], environment: [:]
            )
            let controller = ProcessTerminationController {}
            controller.didLaunch(processGroupID: leader)
            defer {
                controller.requestTermination()
                var status: Int32 = 0
                var reaped: pid_t
                repeat {
                    reaped = waitpid(leader, &status, 0)
                } while reaped == -1 && errno == EINTR
                XCTAssertEqual(reaped, leader)
                XCTAssertEqual(ProcessExit(waitStatus: status).exitCode, 128 + SIGKILL)
            }

            ProcessTerminationController.reportTerminationFailure(EPERM, processGroupID: leader)
        }

        XCTAssertTrue(logs.contains("Failed to terminate command process group (errno \(EPERM))"), logs)
        XCTAssertFalse(logs.contains("No live command process group members observed"), logs)
    }

    func testPermissionFailureRemainsAnErrorWithoutACompleteZombieOnlyGroup() throws {
        let leader: pid_t = 42
        let zombie = member(pid: leader, group: leader, status: SZOMB)
        let snapshots: [[kinfo_proc]?] = [
            nil,
            [],
            [member(pid: 43, group: leader, status: SZOMB)],
            [member(pid: leader, group: leader, status: SRUN)],
            [zombie, member(pid: 43, group: leader, status: SRUN)],
            [zombie, member(pid: 43, group: 44, status: SZOMB)]
        ]

        for snapshot in snapshots {
            let logs = try captureLogs {
                ProcessTerminationController.reportTerminationFailure(EPERM, processGroupID: leader) { group in
                    XCTAssertEqual(group, leader)
                    errno = EIO
                    return snapshot
                }
            }

            XCTAssertTrue(logs.contains("Failed to terminate command process group (errno \(EPERM))"), logs)
            XCTAssertFalse(logs.contains("No live command process group members observed"), logs)
        }
    }

    func testMultipleObservedZombieMembersRecordOnlyADebugObservation() throws {
        let leader: pid_t = 42
        let logs = try captureLogs {
            ProcessTerminationController.reportTerminationFailure(EPERM, processGroupID: leader) { _ in
                [
                    self.member(pid: leader, group: leader, status: SZOMB),
                    self.member(pid: 43, group: leader, status: SZOMB)
                ]
            }
        }

        XCTAssertTrue(logs.contains("[DEBUG] [subprocess] No live command process group members observed"), logs)
        XCTAssertFalse(logs.contains("Failed to terminate command process group"), logs)
    }

    func testOtherTerminationErrorsPreserveTheirSeverityWithoutReadingTheGroup() throws {
        for code in [ESRCH, EACCES, EINVAL] {
            let logs = try captureLogs {
                ProcessTerminationController.reportTerminationFailure(code, processGroupID: 42) { _ in
                    XCTFail("Only EPERM needs a process group observation")
                    return nil
                }
            }

            if code == ESRCH {
                XCTAssertTrue(logs.isEmpty, logs)
            } else {
                XCTAssertTrue(logs.contains("[ERROR] [subprocess] Failed to terminate command process group"), logs)
                XCTAssertTrue(logs.contains("(errno \(code))"), logs)
            }
        }
    }

    private func withExitedLeader(_ operation: (pid_t) -> Void) throws {
        let leader = try StreamingProcessRunner.spawn(
            executable: "/usr/bin/true", arguments: [], environment: [:]
        )
        defer {
            var status: Int32 = 0
            var reaped: pid_t
            repeat {
                reaped = waitpid(leader, &status, 0)
            } while reaped == -1 && errno == EINTR
            XCTAssertEqual(reaped, leader)
            XCTAssertEqual(status, 0)
        }

        var info = siginfo_t()
        var observed: Int32
        repeat {
            observed = waitid(P_PID, id_t(leader), &info, WEXITED | WNOWAIT)
        } while observed == -1 && errno == EINTR
        XCTAssertEqual(observed, 0)
        guard observed == 0 else { return }
        XCTAssertEqual(info.si_pid, leader)
        operation(leader)
    }

    private func member(pid: pid_t, group: pid_t, status: Int32) -> kinfo_proc {
        var member = kinfo_proc()
        member.kp_proc.p_pid = pid
        member.kp_proc.p_stat = Int8(status)
        member.kp_eproc.e_pgid = group
        return member
    }

    private func captureLogs(_ operation: () throws -> Void) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EgasuTests.ProcessTermination.\(UUID().uuidString)", isDirectory: true)
        let sink = LogFile(directory: directory, fileName: "egasu.log")
        sink.open()
        let previous = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.debug)
        defer {
            AppLog.sink = previous
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }

        try operation()
        return try String(contentsOf: directory.appendingPathComponent("egasu.log"), encoding: .utf8)
    }
}
