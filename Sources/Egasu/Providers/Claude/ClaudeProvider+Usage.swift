import Foundation

extension ClaudeProvider {
    struct ProfileScopeRemoved: Error {
        let persisted: Bool
    }

    func fetchLiveUsage(
        state: inout ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration,
        rejectedGrant: inout ClaudeUsageStateStore.AuthenticationFailure?,
        requestedAt: Date
    ) async throws -> ClaudeMappedUsage {
        let config = try authStore.oauthConfig()
        let accountKey: String
        var verifiedThroughProfile = false
        let identity = state.accountIdentityKey
        if let identity, identity.contains("|") {
            let components = identity.split(separator: "|", omittingEmptySubsequences: false)
            guard components.count == 2,
                  components.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                AppLog.error(LogTag.plugin("claude"), "usage blocked: invalid account identity")
                throw ClaudeUsageStateStore.StoreError.identityUnavailable
            }
        }
        // 공유 로그인과 계정 정보는 따로 기록되므로 사용량을 저장하기 전에 토큰 소유자 확인.
        if let identity, identity.contains("|"), state.sharedLoginRoute == nil {
            accountKey = identity
        } else {
            if case .accountSnapshot = state.source, state.accountIdentityKey?.nilIfEmpty == nil {
                AppLog.error(LogTag.plugin("claude"), "saved account usage blocked: account identity unavailable")
                throw ClaudeUsageStateStore.StoreError.identityUnavailable
            }
            accountKey = try await recoverUsageIdentity(
                state: &state, credentialGeneration: &credentialGeneration, rejectedGrant: &rejectedGrant,
                config: config
            )
            verifiedThroughProfile = true
        }
        let lease = try await usageStateStore.acquire(accountKey: accountKey, usageURL: config.usageURL)
        defer { withExtendedLifetime(lease) {} }
        var record = try await loadOffMainActor { try lease.read() }
        try await validateUsageCredentials(state, expected: credentialGeneration)
        try Task.checkCancellation()

        if let until = record.retryAfter, now() < until {
            AppLog.info(LogTag.plugin("claude"), "rate-limited (saved cooldown active)")
            return rateLimitedUsage(record, credentials: state.oauth)
        }
        // 잠금을 기다린 앱·CLI는 방금 끝난 같은 계정의 결과를 공유하며 수동 요청도 중복 전송하지 않음.
        if let completedAt = record.completedAt, completedAt <= now(),
           (completedAt > requestedAt || (lease.waited && completedAt == requestedAt)) {
            if let failure = record.lastFailure { throw failure }
            if let failure = record.authenticationFailure?.error(matching: state.oauth, config: config) {
                if failure == .sessionExpired { rejectedGrant = record.authenticationFailure }
                throw failure
            }
            if var cached = record.lastGood, record.retryAfter == nil, record.authenticationFailure == nil {
                cached.liveQuotaObservedAt = nil
                return cached
            }
        }

        do {
            var expectedGeneration = credentialGeneration
            defer { credentialGeneration = expectedGeneration }
            // 프로필에서 확인한 토큰은 바로 사용하고, 만료 시 사용량 요청의 인증 재시도로 갱신.
            if !verifiedThroughProfile, authStore.needsRefresh(state.oauth),
               let refreshToken = state.oauth.refreshToken, !refreshToken.isEmpty {
                let refreshed = try await refreshAccessToken(
                    state: &state, refreshToken: refreshToken, expectedGeneration: expectedGeneration,
                    rejectedGrant: &rejectedGrant, config: config
                )
                state.oauth.accessToken = refreshed.accessToken
                if refreshed.persisted { expectedGeneration = expectedGeneration.replacing(state) }
            }

            var working = state
            defer { state = working }
            let response = try await ProviderAuthRetry.fetch(
                provider: "claude",
                token: working.oauth.accessToken ?? "",
                attempt: { try await self.usageClient.fetchUsage(accessToken: $0, config: config) },
                refreshAccessToken: {
                    if working.source == .desktop { throw ClaudeAuthError.desktopTokenExpired }
                    guard let refreshToken = working.oauth.refreshToken, !refreshToken.isEmpty else {
                        throw ClaudeAuthError.tokenExpired
                    }
                    let refreshed = try await self.refreshAccessToken(
                        state: &working, refreshToken: refreshToken, expectedGeneration: expectedGeneration,
                        rejectedGrant: &rejectedGrant, config: config
                    )
                    if refreshed.persisted { expectedGeneration = expectedGeneration.replacing(working) }
                    return refreshed.accessToken
                },
                connectionFailed: ClaudeUsageError.connectionFailed,
                authExpired: ClaudeAuthError.tokenExpired
            )
            let observedAt = now()
            if response.statusCode == 429 {
                record.rateLimited(
                    now: observedAt,
                    retryAfterSeconds: ClaudeUsageMapper.parseRetryAfterSeconds(response, now: observedAt)
                )
                let saved = record
                try await loadOffMainActor { try lease.save(saved) }
                AppLog.warn(LogTag.plugin("claude"), "usage rate limited; account cooldown saved")
                try await validateUsageCredentials(working, expected: expectedGeneration)
                return rateLimitedUsage(record, credentials: working.oauth)
            }

            try await validateUsageCredentials(working, expected: expectedGeneration)
            try Task.checkCancellation()
            var mapped = try ClaudeUsageMapper.mapUsageResponse(response, credentials: working.oauth, now: observedAt)
            mapped.liveQuotaObservedAt = observedAt
            mapped.quotaObservedAt = observedAt
            record.succeeded(mapped, at: observedAt)
            let saved = record
            try await loadOffMainActor { try lease.save(saved) }
            usageTimerCredentialState = working
            usageTimerCredentialState?.sourceText = nil
            let verifiedKey = UsageTimerObservation.accountKey(family: "claude", identity: accountKey)
            mapped.liveQuotaAccountKey = verifiedKey
            if let identity, !identity.contains("|"), let token = working.oauth.accessToken {
                mapped.legacySwitchIdentity = .init(identityKey: accountKey, accessToken: token)
            }
            let haikuLimits = mapped.lines.filter { $0.label == "Session" || $0.label == "Weekly" }
            usageTimerObservations =
                working.oauth.hasOnlyProfileScope || UsageTimerObservation.hasExhaustedQuota(haikuLimits)
                ? []
                : [
                    UsageTimerObservation.from(
                        lines: mapped.lines, accountKey: verifiedKey,
                        timerID: "claude.session", observedAt: observedAt, startRule: .missingReset
                    )
                ].compactMap { $0 }
            return mapped
        } catch {
            let failure: ClaudeUsageError? = switch error {
            case let error as ClaudeUsageError: error
            case is DecodingError: .invalidResponse
            case let error as URLError where error.code != .cancelled: .connectionFailed
            default: nil
            }
            let authenticationFailure = ClaudeUsageStateStore.AuthenticationFailure(error, credentials: state.oauth, config: config)
            guard !Task.isCancelled else { throw error }
            if let failure {
                record.failed(failure, at: now())
            } else if let authenticationFailure {
                record.failed(authenticationFailure, at: now())
            } else {
                throw error
            }
            let saved = record
            try await loadOffMainActor { try lease.save(saved) }
            if let failure { throw failure }
            throw error
        }
    }

    private func recoverUsageIdentity(
        state: inout ClaudeCredentialState,
        credentialGeneration: inout ClaudeCredentialGeneration,
        rejectedGrant: inout ClaudeUsageStateStore.AuthenticationFailure?,
        config: ClaudeOAuthConfig
    ) async throws -> String {
        // 신원 확인 전 토큰 갱신도 앱·CLI 사이에서 직렬화. 계정 잠금은 이 잠금을 해제한 뒤 획득.
        let lease = try await usageStateStore.acquire(accountKey: "identity-recovery", usageURL: config.usageURL)
        defer { withExtendedLifetime(lease) {} }
        try await validateUsageCredentials(state, expected: credentialGeneration)
        try Task.checkCancellation()
        var working = state
        var expectedGeneration = credentialGeneration
        defer {
            state = working
            credentialGeneration = expectedGeneration
        }
        do {
            let response = try await ProviderAuthRetry.fetch(
                provider: "claude",
                resource: "profile",
                token: working.oauth.accessToken ?? "",
                attempt: { try await self.usageClient.fetchProfile(accessToken: $0, config: config) },
                refreshAccessToken: {
                    if working.source == .desktop { throw ClaudeAuthError.desktopTokenExpired }
                    guard let refreshToken = working.oauth.refreshToken, !refreshToken.isEmpty else {
                        throw ClaudeAuthError.tokenExpired
                    }
                    let refreshed = try await self.refreshAccessToken(
                        state: &working, refreshToken: refreshToken, expectedGeneration: expectedGeneration,
                        rejectedGrant: &rejectedGrant, config: config
                    )
                    if refreshed.persisted { expectedGeneration = expectedGeneration.replacing(working) }
                    return refreshed.accessToken
                },
                connectionFailed: ClaudeUsageError.connectionFailed,
                authExpired: ClaudeAuthError.tokenExpired
            )
            try await validateUsageCredentials(working, expected: expectedGeneration)
            try Task.checkCancellation()
            try ProviderAuthRetry.requireSuccess(
                response, authExpired: ClaudeAuthError.tokenExpired, requestFailed: ClaudeUsageError.requestFailed
            )
            let profile = try JSONDecoder().decode(ClaudeProfileResponse.self, from: response.body)
            let identity = try profile.accountIdentityKey()
            if let expectedIdentity = expectedGeneration.candidates.compactMap(\.accountIdentityKey).first {
                let verifiedIdentity = expectedIdentity.contains("|") ? identity : String(identity.prefix { $0 != "|" })
                guard verifiedIdentity == expectedIdentity else {
                    throw ClaudeUsageStateStore.StoreError.identityUnavailable
                }
            }
            // 프로필 신원은 사용량 저장 키로만 사용. 로컬 credential 세대와 홈 메타데이터는 변경하지 않음.
            return identity
        } catch let change as ProfileScopeRemoved {
            throw change
        } catch {
            try ProviderAuthRetry.rethrowCancellation(error)
            AppLog.error(LogTag.plugin("claude"), "usage account verification failed")
            if error is DecodingError { throw ClaudeUsageError.invalidResponse }
            throw error
        }
    }

    private func validateUsageCredentials(
        _ state: ClaudeCredentialState, expected: ClaudeCredentialGeneration
    ) async throws {
        let allowInteraction = ProviderRefreshContext.isManual
        let current = try await loadOffMainActor { [authStore] in
            try authStore.credentialGeneration(
                forceDesktopFallback: state.source == .desktop,
                allowAccountInteraction: allowInteraction
            )
        }
        guard current == expected else { throw ClaudeAuthError.credentialsChanged }
    }

    private func rateLimitedUsage(
        _ record: ClaudeUsageStateStore.Record, credentials: ClaudeOAuth
    ) -> ClaudeMappedUsage {
        let seconds = record.retryAfter.map {
            Int(min(Double(Int.max / 2), max(0, $0.timeIntervalSince(now()).rounded(.up))))
        }
        var mapped = record.lastGood ?? ClaudeUsageMapper.rateLimitedUsage(
            credentials: credentials, retryAfterSeconds: seconds
        )
        if record.lastGood != nil {
            mapped.lines.append(ClaudeUsageMapper.rateLimitedNote(retryAfterSeconds: seconds))
            mapped.warning = ClaudeUsageMapper.rateLimitedWarning(retryAfterSeconds: seconds)
            mapped.warningPresentation = ClaudeUsageMapper.rateLimitedWarningPresentation(retryAfterSeconds: seconds)
        }
        mapped.liveQuotaObservedAt = nil
        mapped.retryAfter = record.retryAfter
        return mapped
    }

    private struct RefreshedAccess {
        var accessToken: String
        var persisted: Bool
    }

    private func refreshAccessToken(
        state: inout ClaudeCredentialState,
        refreshToken: String,
        expectedGeneration: ClaudeCredentialGeneration,
        rejectedGrant: inout ClaudeUsageStateStore.AuthenticationFailure?,
        config: ClaudeOAuthConfig
    ) async throws -> RefreshedAccess {
        // 같은 조회의 다른 출처에 복사된 폐기 토큰은 한 번만 제출.
        if rejectedGrant?.rejectsRefreshGrant(for: state.oauth, config: config) == true {
            try await validateUsageCredentials(state, expected: expectedGeneration)
            throw ClaudeAuthError.sessionExpired
        }
        let allowAccountInteraction = ProviderRefreshContext.isManual
        let rotationCandidate = state
        let rotation = try await loadOffMainActor { [authStore] in
            try authStore.beginManagedRotation(
                for: rotationCandidate, ifUnchanged: expectedGeneration,
                allowAccountInteraction: allowAccountInteraction)
        }
        defer { withExtendedLifetime(rotation) {} }
        try Task.checkCancellation()
        // 요청 전송부터 저장까지 앱 종료 보류.
        try TokenRotationShutdownGuard.begin()
        defer { TokenRotationShutdownGuard.end() }

        // 서버가 기존 토큰을 소비한 뒤 조회 취소로 응답이나 저장을 잃지 않도록 별도 Task에서 완료.
        let rotationTask = Task { @MainActor [state, rejectedGrant] in
            var state = state
            var rejectedGrant = rejectedGrant
            let result: Result<RefreshedAccess, Error>
            do {
                result = .success(
                    try await performRotation(
                        state: &state, refreshToken: refreshToken, expectedGeneration: expectedGeneration,
                        rejectedGrant: &rejectedGrant, config: config, allowAccountInteraction: allowAccountInteraction
                    ))
            } catch {
                result = .failure(error)
            }
            return (state, rejectedGrant, result)
        }
        let (updatedState, updatedRejectedGrant, result) = await rotationTask.value
        state = updatedState
        rejectedGrant = updatedRejectedGrant
        return try result.get()
    }

    private func performRotation(
        state: inout ClaudeCredentialState,
        refreshToken: String,
        expectedGeneration: ClaudeCredentialGeneration,
        rejectedGrant: inout ClaudeUsageStateStore.AuthenticationFailure?,
        config: ClaudeOAuthConfig,
        allowAccountInteraction: Bool
    ) async throws -> RefreshedAccess {
        AppLog.info(LogTag.auth("claude"), "token refresh attempt")
        let decoded: ClaudeRefreshResponse
        do {
            let response = try await usageClient.refreshToken(refreshToken, scopes: state.oauth.scopes, config: config)
            if response.statusCode == 400 || response.statusCode == 401 {
                let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
                let errorCode = body?["error"] as? String ?? body?["error_description"] as? String
                if errorCode == "invalid_grant" {
                    try await validateUsageCredentials(state, expected: expectedGeneration)
                    rejectedGrant = .init(ClaudeAuthError.sessionExpired, credentials: state.oauth, config: config)
                    throw ClaudeAuthError.sessionExpired
                }
                // 인식 못한 OAuth 에러 코드의 400/401은 만료 확정 아님(proxy/WAF/gateway 가능) —
                // 재로그인 안내 대신 HTTP status 표면화.
                throw ClaudeUsageError.requestFailed(response.statusCode)
            }
            guard (200..<300).contains(response.statusCode) else {
                throw ClaudeUsageError.requestFailed(response.statusCode)
            }
            // decoded.accessToken / refreshToken 로깅 금지 — rotation 발생 사실만 기록.
            decoded = try JSONDecoder().decode(ClaudeRefreshResponse.self, from: response.body)
        } catch ClaudeAuthError.credentialsChanged {
            AppDiagnostics.record(.credentialRefresh, result: .bindingChanged, providerID: provider.id)
            throw ClaudeAuthError.credentialsChanged
        } catch {
            AppDiagnostics.failure(.credentialRefresh, error: error, providerID: provider.id, localContext: "token refresh request failed")
            throw error
        }
        AppDiagnostics.record(.credentialRefresh, result: .success, providerID: provider.id)
        if let scope = decoded.scope { state.oauth.scopes = scope.split(separator: " ").map(String.init) }
        state.oauth.accessToken = decoded.accessToken
        if let refreshToken = decoded.refreshToken {
            state.oauth.refreshToken = refreshToken
        }
        if let expiresIn = decoded.expiresIn {
            state.oauth.expiresAt = now().timeIntervalSince1970 * 1000 + expiresIn * 1000
        }
        // loudly 실패: save 누락 시 구 refresh token이 디스크에 남아 다음 launch가 무효 토큰으로
        // "session expired" 오인; refresh된 토큰은 이번 세션에 유효하므로 로그 후 계속.
        let persisted: Bool
        do {
            guard try await Task.detached(priority: .utility, operation: { [authStore, state] in
                try authStore.save(
                    state, ifUnchanged: expectedGeneration, allowAccountInteraction: allowAccountInteraction
                )
            }).value else {
                throw ClaudeAuthError.credentialsChanged
            }
            persisted = true
            AppDiagnostics.record(.credentialSave, result: .success, providerID: provider.id)
            AppLog.info(LogTag.auth("claude"), "token refresh ok (rotated)")
        } catch let error as ClaudeAuthError where error == .credentialsChanged {
            AppDiagnostics.record(.credentialSave, result: .bindingChanged, providerID: provider.id)
            throw error
        } catch {
            persisted = false
            refreshIsDegraded = true
            AppDiagnostics.record(.credentialSave, result: .degraded, providerID: provider.id, error: error,
                                  localContext: "failed to persist rotated credentials; using the refreshed token for this session only")
        }
        // 회전한 인증을 저장한 뒤 새 권한으로 프로필·사용량 재시도 여부 확인.
        guard authStore.liveUsageAvailability(state) != .missingProfileScope else {
            throw ProfileScopeRemoved(persisted: persisted)
        }
        return RefreshedAccess(accessToken: decoded.accessToken, persisted: persisted)
    }

}
