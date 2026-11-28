import XCTest
@testable import Egasu

final class AccountsLocalizationTests: XCTestCase {
    func testNumberedAccountNamesUseConsistentSpacingInEveryLanguage() {
        let expected: [LanguageSetting: [String]] = [
            .english: ["Account 2", "Work · Account 2"],
            .korean: ["계정 2", "Work · 계정 2"],
            .japanese: ["アカウント2", "Work · アカウント2"]
        ]
        for language in LanguageSetting.allCases {
            let labels = L10n.withLanguage(language) {
                [L10n.accounts("Account %lld", 2), L10n.accounts("%@ · Account %lld", "Work", 2)]
            }
            XCTAssertEqual(labels, expected[language])
        }
    }

    func testMetricReorderAnnouncementNamesTheMetricAndPreservesPositionInEveryLanguage() {
        let expected: [LanguageSetting: String] = [
            .english: "Moved metric Session to position 2 of 3.",
            .korean: "세션 지표를 전체 3개 중 2번째로 이동했습니다.",
            .japanese: "指標「セッション」を全 3 件中 2 番目に移動しました。"
        ]
        for language in LanguageSetting.allCases {
            let message = L10n.withLanguage(language) {
                L10n.accounts("Moved metric %@ to position %lld of %lld.", L10n.metrics("Session"), 2, 3)
            }
            XCTAssertEqual(message, expected[language])
        }
    }

    func testConditionalAccountActionsAndKeyPromptsUseEveryLanguage() {
        let keys = ["Optional", "Required", "Sign In Again…", "Add API Key…", "Replace API Key…", "Signing In…"]
        let expected: [LanguageSetting: [String]] = [
            .english: keys,
            .korean: ["선택", "필수", "다시 로그인…", "API 키 추가…", "API 키 교체…", "로그인 중…"],
            .japanese: ["任意", "必須", "再ログイン…", "APIキーを追加…", "APIキーを置き換え…", "ログイン中…"]
        ]
        for language in LanguageSetting.allCases {
            XCTAssertEqual(L10n.withLanguage(language) { keys.map { L10n.accounts($0) } }, expected[language])
        }
    }

    func testFirstAccountRetryAndExplicitSignInHaveSeparateLocalizedLabels() {
        for (language, retry, signIn) in [
            (LanguageSetting.english, "Try Again", "Sign In Again"),
            (.korean, "다시 시도", "다시 로그인"),
            (.japanese, "再試行", "再ログイン")
        ] {
            L10n.withLanguage(language) {
                XCTAssertEqual(L10n.accounts("Try Again"), retry)
                XCTAssertEqual(L10n.accounts("Sign In Again"), signIn)
            }
        }
    }

    func testRenameFailureMessagesMatchEveryLanguage() {
        let expected: [LanguageSetting: [String]] = [
            .english: ["Couldn't Rename Account", "The sign-in email is unavailable. Enter an account name."],
            .korean: ["계정 이름을 변경하지 못했습니다", "로그인 이메일을 확인할 수 없습니다. 계정 이름을 입력해 주세요."],
            .japanese: ["アカウント名を変更できませんでした", "ログイン用のメールアドレスを確認できません。アカウント名を入力してください。"]
        ]

        for language in LanguageSetting.allCases {
            let messages = L10n.withLanguage(language) {
                [
                    L10n.accounts("Couldn't Rename Account"),
                    L10n.accounts("The sign-in email is unavailable. Enter an account name.")
                ]
            }
            XCTAssertEqual(messages, expected[language])
        }
    }

    func testMetricSettingsGroupTitlesMatchEveryLanguage() {
        let expected: [LanguageSetting: [String]] = [
            .english: ["Account Settings", "Shared Settings"],
            .korean: ["계정 설정", "공통 설정"],
            .japanese: ["アカウント設定", "共通設定"]
        ]

        for language in LanguageSetting.allCases {
            let titles = L10n.withLanguage(language) {
                [L10n.accounts("Account Settings"), L10n.accounts("Shared Settings")]
            }
            XCTAssertEqual(titles, expected[language])
        }
    }

    func testOpenActionPreservesTheAccountNameInEveryLanguage() {
        let name = "Claude — 50% 개인 %@"
        let expected: [LanguageSetting: String] = [
            .english: "Open \(name)",
            .korean: "\(name) 열기",
            .japanese: "\(name)を開く"
        ]

        for language in LanguageSetting.allCases {
            let actual = L10n.withLanguage(language) { L10n.accounts("Open %@", name) }
            XCTAssertEqual(actual, expected[language])
        }
    }
}
