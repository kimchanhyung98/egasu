import Foundation
import XCTest
@testable import Egasu

final class KimiCLIConfigurationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/test")
    private let globalCredentialName = "kimi-code-env-0e4f99c69cc27850"
    private let configurationError = "Kimi configuration is invalid. Check config.toml."
    private let missingAPIKeyError = "Kimi API key is missing. Check the CLI provider settings."

    func testGlobalOAuthUsesConfiguredHomeScopedCredentialAndLock() throws {
        let customHome = home.appendingPathComponent("custom-kimi")
        let store = makeStore(
            config: """
            [providers."managed:kimi-code"]
            type = "kimi"
            base_url = "https://api.kimi.ai/coding/v1"
            [providers."managed:kimi-code".oauth]
            storage = "file"
            key = "oauth/kimi-code-env-0e4f99c69cc27850"
            oauth_host = "https://auth.kimi.ai"
            """,
            credentials: [globalCredentialName: credential("global")],
            environment: ["KIMI_CODE_HOME": "~/custom-kimi"],
            currentHome: customHome
        )

        let document = try XCTUnwrap(store.loadCredentialDocument())

        XCTAssertEqual(document.credentials.accessToken, "global")
        XCTAssertEqual(
            document.credentials.source,
            .current(
                home: customHome,
                credential: customHome.appendingPathComponent("credentials/\(globalCredentialName).json"),
                lockTarget: customHome.appendingPathComponent("oauth/\(globalCredentialName)")
        ))
    }

    func testComOAuthKeepsExistingCredentialLocation() throws {
        let store = makeStore(
            config: providerConfiguration(auth: oauth()),
            credentials: ["kimi-code": credential("com")]
        )

        let document = try XCTUnwrap(store.loadCredentialDocument())

        XCTAssertEqual(document.credentials.accessToken, "com")
        XCTAssertEqual(document.credentials.refreshToken, "com-refresh")
    }

    func testDefaultModelSelectsItsCodeProviderBeforeManagedProvider() throws {
        let store = makeStore(
            config: """
        default_model = "chosen"
        [models.chosen]
        provider = "selected"
        model = "kimi-for-coding"
        [providers.selected]
        type = "kimi"
        base_url = "https://api.kimi.ai/coding/v1"
        api_key = "selected-key"
        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = "https://api.kimi.com/coding/v1"
        api_key = "managed-key"
        """)

        XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "selected-key")
    }

    func testNonCodeDefaultModelDoesNotHideManagedCodeProvider() throws {
        let store = makeStore(
            config: """
        default_model = "other"
        [models.other]
        provider = "anthropic"
        model = "claude-sonnet"
        [providers.anthropic]
        type = "anthropic"
        base_url = "https://api.anthropic.com"
        api_key = "other-key"
        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = "https://api.kimi.ai/coding/v1"
        api_key = "managed-key"
        """)

        XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "managed-key")
    }

    func testManagedProviderWinsWhenThereIsNoCodeDefaultModel() throws {
        let store = makeStore(
            config: """
        [providers.other]
        type = "kimi"
        base_url = "https://api.kimi.ai/coding/v1"
        api_key = "other-key"
        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = "https://api.kimi.com/coding/v1"
        api_key = "managed-key"
        """)

        XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "managed-key")
    }

    func testUniqueCodeProviderIsUsedWithoutManagedProvider() throws {
        let store = makeStore(config: providerConfiguration(name: "my-code", auth: "api_key = 'only-key'"))

        XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "only-key")
    }

    func testAnthropicProtocolCodeEndpointLoadsAPIKey() throws {
        let store = makeStore(
            config: """
        [providers.personal]
        type = "anthropic"
        base_url = "https://api.kimi.ai/coding/"
        api_key = "anthropic-code-key"
        """)

        let document = try XCTUnwrap(store.loadCredentialDocument())

        XCTAssertEqual(document.credentials.accessToken, "anthropic-code-key")
        XCTAssertNil(document.credentials.refreshToken)
    }

    func testMultipleCodeCandidatesWithoutSelectionFailClearly() {
        let config =
            providerConfiguration(name: "first", auth: "api_key = 'first-key'") + "\n"
            + providerConfiguration(name: "second", auth: "api_key = 'second-key'")
        assertError(makeStore(config: config, credentials: ["kimi-code": credential("stale")]), configurationError)
    }

    func testExplicitAPIKeyOverridesProviderEnvironmentFallback() throws {
        let store = makeStore(
            config: providerConfiguration(
                auth: """
        api_key = "explicit-key"
        env = { KIMI_API_KEY = "fallback-key" }
        """))

        let document = try XCTUnwrap(store.loadCredentialDocument())

        XCTAssertEqual(document.credentials.accessToken, "explicit-key")
        XCTAssertNil(document.credentials.refreshToken)
        XCTAssertTrue(store.isUsable(document, now: Date(timeIntervalSince1970: 2_000)))
        XCTAssertFalse(store.needsRefresh(document, now: Date(timeIntervalSince1970: 2_000)))
    }

    func testAPIKeyEnvironmentReferenceOverridesProviderFallback() throws {
        let store = makeStore(
            config: providerConfiguration(
                auth: """
            api_key_env = "MY_KIMI_KEY"
            env = { KIMI_API_KEY = "fallback-key" }
            """),
            environment: ["MY_KIMI_KEY": "referenced-key"]
        )

        XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "referenced-key")
    }

    func testProviderEnvironmentSuppliesAPIKeyAndCodeBaseURL() throws {
        let store = makeStore(
            config: """
        [providers.personal]
        type = "kimi"
        [providers.personal.env]
        KIMI_API_KEY = "provider-env-key"
        KIMI_BASE_URL = "https://api.kimi.ai/coding/v1"
        """)

        XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "provider-env-key")
    }

    func testMissingReferencedEnvironmentKeyDoesNotFallBackToAnotherCredential() {
        for environment in [[:], ["MY_KIMI_KEY": "   "]] {
            let store = makeStore(
                config: providerConfiguration(
                    auth: """
                api_key_env = "MY_KIMI_KEY"
                env = { KIMI_API_KEY = "fallback-key" }
                """),
                credentials: ["kimi-code": credential("stale")],
                environment: environment
            )
            assertError(store, missingAPIKeyError)
        }
    }

    func testAmbientKimiAPIKeyIsNotAnImplicitCLIProviderCredential() {
        let store = makeStore(
            config: providerConfiguration(auth: ""),
            credentials: ["kimi-code": credential("stale")],
            environment: ["KIMI_API_KEY": "ambient-key"]
        )

        assertError(store, missingAPIKeyError)
    }

    func testConflictingExplicitAPIKeySourcesFailClearly() {
        let store = makeStore(
            config: providerConfiguration(
                auth: """
            api_key = "explicit-key"
            api_key_env = "MY_KIMI_KEY"
            """),
            environment: ["MY_KIMI_KEY": "referenced-key"]
        )

        assertError(store, configurationError)
    }

    func testOAuthConflictsWithNonemptyExplicitAPIKeyOrEnvironmentReference() {
        for auth in ["api_key = 'explicit-key'", "api_key_env = 'MY_KIMI_KEY'"] {
            let store = makeStore(
                config: providerConfiguration(auth: auth + "\n" + oauth()),
                credentials: ["kimi-code": credential("oauth")],
                environment: ["MY_KIMI_KEY": "referenced-key"]
            )
            assertError(store, configurationError)
        }
    }

    func testEmptyExplicitAPIKeyDoesNotConflictWithOAuth() throws {
        let store = makeStore(
            config: providerConfiguration(auth: "api_key = ''\n" + oauth()),
            credentials: ["kimi-code": credential("oauth")]
        )

        XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "oauth")
    }

    func testOAuthConflictsWithProviderEnvironmentAPIKey() {
        let store = makeStore(
            config: providerConfiguration(auth: oauth() + "\nenv = { KIMI_API_KEY = 'fallback-key' }"),
            credentials: ["kimi-code": credential("oauth")]
        )

        assertError(store, configurationError)
    }

    func testMalformedTOMLDoesNotFallBackToSavedOAuth() {
        for config in [
            "[providers.\"managed:kimi-code\"\napi_key = 'key'",
            providerConfiguration(auth: "api_key = \"unterminated"),
            providerConfiguration(auth: "api_key = 'first'\napi_key = 'second'")
        ] {
            assertError(makeStore(config: config, credentials: ["kimi-code": credential("stale")]), configurationError)
        }
    }

    func testExternalAndPlatformHostsCannotUseCodeCredentials() {
        for baseURL in [
            "https://example.invalid/coding/v1",
            "https://api.moonshot.ai/v1",
            "https://api.moonshot.cn/v1",
            "https://api.kimi.ai.example.invalid/coding/v1",
            "https://api.kimi.ai/coding/v1?redirect=other"
        ] {
            let store = makeStore(
                config: providerConfiguration(baseURL: baseURL, auth: "api_key = 'platform-key'"),
                credentials: ["kimi-code": credential("stale")]
            )
            assertError(store, KimiAuthError.unsupportedConfiguration.localizedDescription)
        }
    }

    func testMixedOfficialEndpointsNeverReuseOtherSlots() throws {
        let store = makeStore(
            config: providerConfiguration(baseURL: "https://api.kimi.ai/coding/v1", auth: oauth()),
            credentials: [globalCredentialName: credential("global"), "kimi-code": credential("com")]
        )

        XCTAssertNil(try store.loadCredentialDocument())
    }

    func testGlobalEnvironmentOverridesUseMatchingScopedCredential() throws {
        for oauthVariable in ["KIMI_CODE_OAUTH_HOST", "KIMI_OAUTH_HOST"] {
            let store = makeStore(
                config: providerConfiguration(auth: oauth()),
                credentials: [globalCredentialName: credential("global"), "kimi-code": credential("com")],
                environment: [
                    "KIMI_CODE_BASE_URL": "https://api.kimi.ai/coding/v1",
                    oauthVariable: "https://auth.kimi.ai"
                ]
            )

            XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "global")
        }
    }

    func testStaleOAuthKeyIsRecomputedFromConfiguredEndpointPair() throws {
        let store = makeStore(
            config: providerConfiguration(
                baseURL: "https://api.kimi.ai/coding/v1",
                auth: oauth(key: "oauth/kimi-code", host: "https://auth.kimi.ai")
            ),
            credentials: [globalCredentialName: credential("global"), "kimi-code": credential("stale-com")]
        )

        XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "global")
    }

    func testMissingGlobalCredentialNeverFallsBackToComOrLegacy() throws {
        let store = makeStore(
            config: providerConfiguration(
                baseURL: "https://api.kimi.ai/coding/v1",
                auth: oauth(key: "oauth/\(globalCredentialName)", host: "https://auth.kimi.ai")
            ),
            credentials: ["kimi-code": credential("com")],
            legacyCredential: credential("legacy")
        )

        XCTAssertNil(try store.loadCredentialDocument())
    }

    func testMissingComCredentialWithExplicitProviderNeverFallsBackToLegacy() throws {
        let store = makeStore(
            config: providerConfiguration(auth: oauth()),
            legacyCredential: credential("legacy")
        )

        XCTAssertNil(try store.loadCredentialDocument())
    }

    func testConfigurationWithoutProvidersRetainsLegacyCredentialDiscovery() throws {
        for config in [nil, "default_model = 'old-model'\n[loop_control]\nmax_attempts_per_step = 2"] {
            let store = makeStore(config: config, legacyCredential: credential("legacy"))

            XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "legacy")
        }
    }

    func testEmptyProvidersTableDoesNotFallBackToLegacyCredential() {
        let store = makeStore(config: "[providers]", legacyCredential: credential("legacy"))

        assertError(store, KimiAuthError.unsupportedConfiguration.localizedDescription)
    }

    func testIncompleteOAuthReferenceDoesNotAdoptExistingCredential() {
        for reference in [
            "{}",
            "{ key = 'oauth/kimi-code' }",
            "{ storage = 'file' }",
            "{ storage = 'file', key = '' }",
            "{ storage = 'external', key = 'oauth/kimi-code' }"
        ] {
            let store = makeStore(
                config: providerConfiguration(auth: "oauth = \(reference)"),
                credentials: ["kimi-code": credential("existing-account")]
            )

            assertError(store, configurationError)
        }
    }

    func testInvalidDefaultCodeEndpointCannotSelectAnotherManagedAccount() {
        for baseURL in ["https://api.kimi.ai/coding/v1?account=other", "https://api.kimi.ai/wrong-path"] {
            let store = makeStore(
                config: """
            default_model = "chosen"
            [models.chosen]
            provider = "selected"
            model = "kimi-for-coding"
            [providers.selected]
            type = "kimi"
            base_url = "\(baseURL)"
            api_key = "selected-key"
            [providers."managed:kimi-code"]
            type = "kimi"
            base_url = "https://api.kimi.com/coding/v1"
            api_key = "other-account-key"
            """)

            assertError(store, KimiAuthError.unsupportedConfiguration.localizedDescription)
        }
    }

    func testProviderEnvironmentUsesEachProtocolsKeyAndBaseURLNames() throws {
        let cases = [
            ("anthropic", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL", "https://api.kimi.ai/coding/"),
            ("openai", "OPENAI_API_KEY", "OPENAI_BASE_URL", "https://api.kimi.ai/coding/v1"),
            ("openai_responses", "OPENAI_API_KEY", "OPENAI_BASE_URL", "https://api.kimi.ai/coding/v1")
        ]
        for (type, keyName, baseName, baseURL) in cases {
            let store = makeStore(
                config: """
            [providers.personal]
            type = "\(type)"
            [providers.personal.env]
            \(keyName) = "protocol-key"
            \(baseName) = "\(baseURL)"
            """)

            XCTAssertEqual(try store.loadCredentialDocument()?.credentials.accessToken, "protocol-key")
        }
    }

    func testAnthropicProviderDoesNotReadKimiProtocolEnvironmentKey() {
        let store = makeStore(
            config: """
        [providers.personal]
        type = "anthropic"
        base_url = "https://api.kimi.ai/coding/"
        env = { KIMI_API_KEY = "wrong-protocol-key" }
        """)

        assertError(store, missingAPIKeyError)
    }

    private func makeStore(
        config: String? = nil,
        credentials: [String: String] = [:],
        legacyCredential: String? = nil,
        environment: [String: String] = [:],
        currentHome: URL? = nil
    ) -> KimiAuthStore {
        let userHome = home
        let current = currentHome ?? home.appendingPathComponent(".kimi-code")
        var contents: [String: String] = [:]
        if let config { contents[current.appendingPathComponent("config.toml").path] = config }
        for (name, text) in credentials {
            contents[current.appendingPathComponent("credentials/\(name).json").path] = text
        }
        if let legacyCredential {
            contents[home.appendingPathComponent(".kimi/credentials/kimi-code.json").path] = legacyCredential
        }
        return KimiAuthStore(
            files: FakeFiles(contents), environment: FakeEnvironment(environment), homeDirectory: { userHome }
        )
    }

    private func providerConfiguration(
        name: String = "managed:kimi-code",
        baseURL: String = "https://api.kimi.com/coding/v1",
        auth: String
    ) -> String {
        """
        [providers."\(name)"]
        type = "kimi"
        base_url = "\(baseURL)"
        \(auth)
        """
    }

    private func oauth(key: String = "oauth/kimi-code", host: String = "https://auth.kimi.com") -> String {
        "oauth = { storage = 'file', key = '\(key)', oauth_host = '\(host)' }"
    }

    private func credential(_ token: String) -> String {
        #"{"access_token":"\#(token)","refresh_token":"\#(token)-refresh","expires_at":4000,"expires_in":3600}"#
    }

    private func assertError(
        _ store: KimiAuthStore, _ description: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try store.loadCredentialDocument(), file: file, line: line) { error in
            XCTAssertEqual(error.localizedDescription, description, file: file, line: line)
        }
    }
}
