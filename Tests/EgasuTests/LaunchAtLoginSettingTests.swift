import XCTest
@testable import Egasu

@MainActor
final class LaunchAtLoginSettingTests: XCTestCase {
    func testFailedChangeRollsBackWithoutMakingASecondSystemCall() {
        let systemEnabled = false
        var requestedValues: [Bool] = []
        let setting = LaunchAtLoginSetting(
            currentStatus: { systemEnabled },
            setEnabled: { enabled in
                requestedValues.append(enabled)
                throw TestError.rejected
            }
        )

        setting.update(to: true)

        XCTAssertEqual(requestedValues, [true])
        XCTAssertFalse(setting.isEnabled)
        XCTAssertEqual(setting.errorMessage, LaunchAtLoginSetting.failureMessage)
    }

    func testLaterSuccessUpdatesTheSwitchAndClearsTheError() {
        var systemEnabled = false
        var shouldFail = true
        let setting = LaunchAtLoginSetting(
            currentStatus: { systemEnabled },
            setEnabled: { enabled in
                if shouldFail { throw TestError.rejected }
                systemEnabled = enabled
            }
        )
        setting.update(to: true)
        shouldFail = false

        setting.update(to: true)

        XCTAssertTrue(setting.isEnabled)
        XCTAssertNil(setting.errorMessage)
    }

    func testExternalRecoveryClearsTheErrorWithoutAnotherSystemCall() {
        for requested in [true, false] {
            var systemEnabled = !requested
            var requestedValues: [Bool] = []
            let setting = LaunchAtLoginSetting(
                currentStatus: { systemEnabled },
                setEnabled: { enabled in
                    requestedValues.append(enabled)
                    throw TestError.rejected
                }
            )
            setting.refreshStatus()
            setting.update(to: requested)
            XCTAssertNotNil(setting.errorMessage)

            systemEnabled = requested
            setting.refreshStatus()

            XCTAssertEqual(setting.isEnabled, requested)
            XCTAssertNil(setting.errorMessage)
            systemEnabled = !requested
            setting.refreshStatus()
            XCTAssertEqual(setting.isEnabled, !requested)
            XCTAssertNil(setting.errorMessage, "해결한 오류는 이후 외부 변경에도 다시 표시하지 않음")
            XCTAssertEqual(requestedValues, [requested], "상태 재조회는 등록·해제를 다시 요청하지 않음")
        }
    }

    func testRefreshPreservesTheErrorWhileTheFailedChangeIsUnresolved() {
        for requested in [true, false] {
            var requestedValues: [Bool] = []
            let setting = LaunchAtLoginSetting(
                currentStatus: { !requested },
                setEnabled: { enabled in
                    requestedValues.append(enabled)
                    throw TestError.rejected
                }
            )
            setting.refreshStatus()
            setting.update(to: requested)

            setting.refreshStatus()
            setting.refreshStatus()

            XCTAssertEqual(setting.isEnabled, !requested)
            XCTAssertEqual(setting.errorMessage, LaunchAtLoginSetting.failureMessage)
            XCTAssertEqual(requestedValues, [requested])
        }
    }

    func testRefreshRecognizesTheRequestedStateEvenWhenTheFailedCallAppliedIt() {
        for requested in [true, false] {
            var systemEnabled = !requested
            let setting = LaunchAtLoginSetting(
                currentStatus: { systemEnabled },
                setEnabled: { enabled in
                    systemEnabled = enabled
                    throw TestError.rejected
                }
            )
            setting.refreshStatus()
            setting.update(to: requested)
            XCTAssertEqual(setting.isEnabled, requested)
            XCTAssertNotNil(setting.errorMessage)

            setting.refreshStatus()

            XCTAssertEqual(setting.isEnabled, requested)
            XCTAssertNil(setting.errorMessage, "이전 표시값이 아니라 실패한 요청의 목표 상태로 복구 판단")
        }
    }

    func testLaterFailureUsesItsOwnRequestedStateForRecovery() {
        var systemEnabled = false
        var requestedValues: [Bool] = []
        let setting = LaunchAtLoginSetting(
            currentStatus: { systemEnabled },
            setEnabled: { enabled in
                requestedValues.append(enabled)
                throw TestError.rejected
            }
        )
        setting.update(to: true)
        systemEnabled = true
        setting.refreshStatus()
        XCTAssertNil(setting.errorMessage)

        setting.update(to: false)
        setting.refreshStatus()
        XCTAssertEqual(setting.errorMessage, LaunchAtLoginSetting.failureMessage)
        systemEnabled = false
        setting.refreshStatus()

        XCTAssertFalse(setting.isEnabled)
        XCTAssertNil(setting.errorMessage)
        XCTAssertEqual(requestedValues, [true, false])
    }

    func testFailureMessageUsesEachScopedLanguageWhenTheErrorOccurs() {
        let setting = LaunchAtLoginSetting(
            currentStatus: { false },
            setEnabled: { _ in throw TestError.rejected }
        )
        let expected: [(LanguageSetting, String)] = [
            (.english, "macOS wouldn't update Launch at Login. Check System Settings → Login Items."),
            (.korean, "macOS에서 로그인 시 실행 설정을 변경하지 못했습니다. 시스템 설정 → 로그인 항목을 확인하세요."),
            (.japanese, "macOSでログイン時の起動設定を変更できませんでした。システム設定 → ログイン項目を確認してください。")
        ]

        for (language, message) in expected {
            L10n.withLanguage(language) {
                setting.update(to: true)
                XCTAssertEqual(setting.errorMessage, message)
            }
        }
    }

    private enum TestError: Error {
        case rejected
    }
}
