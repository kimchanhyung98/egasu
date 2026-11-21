import XCTest
import UserNotifications
@testable import Egasu

/// 시스템 center 접근 차단과 주입된 권한·예약·제거 경계에서 계정 교체 검증.
@MainActor
final class AppNotificationsTests: XCTestCase {
    func testIsRunningUnderTestsIsTrueInTheHarness() {
        XCTAssertTrue(AppNotifications.isRunningUnderTests)
    }

    func testShowHandlerIsInvokedByShow() {
        var opened = false
        MenuBarPopover.showHandler = { opened = true }
        defer { MenuBarPopover.showHandler = nil }
        MenuBarPopover.show()
        XCTAssertTrue(opened)
    }

    func testPostIsANoOpUnderTestsAndNeverTouchesTheCenter() async {
        let probe = CenterProbe()
        let notifications = AppNotifications(centerProvider: {
            probe.touched = true
            return UNUserNotificationCenter.current()
        })
        _ = await notifications.post(idPrefix: "claude.session.healthyToClose", title: "Warning", subtitle: "Claude Session", body: "x")
        notifications.registerAsDelegate()
        XCTAssertFalse(probe.touched, "Under tests, no notification path should reach the center provider")
    }

    func testAccountChangeDuringAuthorizationPreventsSubmission() async throws {
        let request = notificationRequest()
        var current = true
        var submitted: [String] = []
        var removed: [String] = []
        let delivered = try await AppNotifications.deliver(
            request,
            isCurrent: { current },
            authorize: { current = false; return true },
            add: { submitted.append($0.identifier) },
            remove: { removed.append($0) }
        )
        XCTAssertFalse(delivered)
        XCTAssertTrue(submitted.isEmpty)
        XCTAssertTrue(removed.isEmpty)
    }

    func testAccountChangeDuringSubmissionRemovesOnlyThatRequest() async throws {
        let request = notificationRequest()
        var current = true
        var submitted: [String] = []
        var removed: [String] = []
        let delivered = try await AppNotifications.deliver(
            request,
            isCurrent: { current },
            authorize: { true },
            add: {
                submitted.append($0.identifier)
                current = false
            },
            remove: { removed.append($0) }
        )
        XCTAssertFalse(delivered)
        XCTAssertEqual(submitted, [request.identifier])
        XCTAssertEqual(removed, [request.identifier])
    }

    func testCurrentAccountDeliveryIsKeptAndDeniedAuthorizationDoesNotSubmit() async throws {
        for authorized in [true, false] {
            let request = notificationRequest()
            var submitted: [String] = []
            var removed: [String] = []
            let delivered = try await AppNotifications.deliver(
                request,
                isCurrent: { true },
                authorize: { authorized },
                add: { submitted.append($0.identifier) },
                remove: { removed.append($0) }
            )
            XCTAssertEqual(delivered, authorized)
            XCTAssertEqual(submitted, authorized ? [request.identifier] : [])
            XCTAssertTrue(removed.isEmpty)
        }
    }

    func testEveryDeliveryReadsCurrentPermissionAfterCachedGrantOrDenial() async throws {
        for originallyGranted in [true, false] {
            var requestCount = 0
            let authorization = Task<Bool, Never> {
                requestCount += 1
                return originallyGranted
            }
            var statusReads = 0
            var submitted = 0
            var expectedSubmissions = 0
            let statuses: [UNAuthorizationStatus] = [.authorized, .denied, .authorized, .provisional, .notDetermined]
            for (index, status) in statuses.enumerated() {
                let expected = status == .authorized || status == .provisional
                let delivered = try await AppNotifications.deliver(
                    notificationRequest(),
                    isCurrent: { true },
                    authorize: {
                        await AppNotifications.isAuthorizedForDelivery(
                            idPrefix: "test", authorization: authorization,
                            authorizationStatus: { statusReads += 1; return status }
                        )
                    },
                    add: { _ in submitted += 1 },
                    remove: { _ in XCTFail("계정이 유지되면 전달 요청을 제거하지 않음") }
                )
                if expected { expectedSubmissions += 1 }
                XCTAssertEqual(delivered, expected, "현재 권한 \(status.rawValue), 이전 허용 \(originallyGranted)")
                XCTAssertEqual(submitted, expectedSubmissions)
                XCTAssertEqual(statusReads, index + 1, "전달 시도마다 현재 권한 조회는 한 번")
            }
            XCTAssertEqual(requestCount, 1, "최초 권한 요청은 공유하고 상태만 다시 조회")
        }
    }

    func testAccountChangeDuringLivePermissionCheckPreventsSubmission() async throws {
        var current = true
        let delivered = try await AppNotifications.deliver(
            notificationRequest(),
            isCurrent: { current },
            authorize: {
                await AppNotifications.isAuthorizedForDelivery(
                    idPrefix: "test", authorization: Task { true },
                    authorizationStatus: { current = false; return .authorized }
                )
            },
            add: { _ in XCTFail("현재 권한을 읽는 동안 교체된 계정은 제출하지 않음") },
            remove: { _ in XCTFail("제출하지 않은 요청은 제거하지 않음") }
        )
        XCTAssertFalse(delivered)
    }

    private func notificationRequest() -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: "test-\(UUID().uuidString)",
            content: UNMutableNotificationContent(),
            trigger: nil
        )
    }

    /// `@Sendable` provider closure의 실행 여부 기록용 참조 box
    private final class CenterProbe: @unchecked Sendable {
        var touched = false
    }
}
