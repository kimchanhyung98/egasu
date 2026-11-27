import Foundation

/// Reset-credit 소비 결과. 실패한 요청은 사용자 확인 대상을 바꾸지 않고 같은 요청으로만 재시도.
enum ResetClaimOutcome: Equatable, Sendable {
    case success
    case nothingToReset
    case noCredit
    case failed
}

/// 표시한 사용량의 인증 출처·주체로만 크레딧 소비. 재시도도 같은 확인·크레딧에 결합.
@MainActor
final class CodexResetClaimService {
    struct MatchedCredit {
        let binding: CodexResetClaimBinding
        let expiry: Date
        let creditID: String
        let remainingAtExpiry: Int?
    }

    enum CreditSelection: Equatable {
        case available(id: String, remaining: Int?)
        case unavailable
        case emptyInventory
        case unknown
    }

    enum UnavailableCredits {
        case credit(MatchedCredit, confirmedExpiries: [Date]? = nil)
        case replayed(MatchedCredit, confirmedExpiries: [Date]?)
        case expiry(binding: CodexResetClaimBinding, date: Date)
        case emptyInventory(binding: CodexResetClaimBinding, selectedExpiry: Date)
    }

    /// 카드 서비스 교체 후에도 같은 확인 요청의 크레딧·진행 상태 유지.
    @MainActor
    final class RequestState {
        fileprivate var matchedCredits: [String: MatchedCredit] = [:]
        fileprivate var activeRequestIDs: Set<String> = []
    }

    private let usageClient: CodexUsageClient
    private let credentialLoader: (CodexAuthState.Source, Bool) async throws -> CodexAuthState?
    private let isCurrent: () -> Bool
    private let refreshAfterClaim: (CodexResetClaimBinding) async -> Void
    private let workQueue: BackgroundWorkQueue
    var onUnavailable: ((UnavailableCredits) -> Void)?
    let requestState: RequestState

    init(
        usageClient: CodexUsageClient,
        credentialLoader: @escaping (CodexAuthState.Source, Bool) async throws -> CodexAuthState?,
        requestState: RequestState = RequestState(),
        isCurrent: @escaping () -> Bool = { true },
        refreshAfterClaim: @escaping (CodexResetClaimBinding) async -> Void = { _ in },
        workQueue: BackgroundWorkQueue = BackgroundWorkQueue()
    ) {
        self.usageClient = usageClient
        self.credentialLoader = credentialLoader
        self.requestState = requestState
        self.isCurrent = isCurrent
        self.refreshAfterClaim = refreshAfterClaim
        self.workQueue = workQueue
    }

    convenience init(
        authStore: CodexAuthStore,
        usageClient: CodexUsageClient,
        requestState: RequestState = RequestState(),
        isCurrent: @escaping () -> Bool = { true },
        refreshAfterClaim: @escaping (CodexResetClaimBinding) async -> Void,
        workQueue: BackgroundWorkQueue = BackgroundWorkQueue()
    ) {
        self.init(
            usageClient: usageClient,
            credentialLoader: { source, allowInteraction in
                try await loadOffMainActor {
                    switch source {
                    case .file(let path):
                        guard authStore.authPaths().contains(path) else { return nil }
                        return authStore.loadAuth(at: path)
                    case .keychain:
                        return try authStore.loadKeychainAuth(allowInteraction: allowInteraction)
                    case .accountSnapshot(let profileID):
                        guard authStore.scope == .accountSnapshot(profileID: profileID) else { return nil }
                        return try authStore.loadAccountSnapshot(profileID: profileID, allowInteraction: allowInteraction)
                    }
                }
            },
            requestState: requestState,
            isCurrent: isCurrent,
            refreshAfterClaim: refreshAfterClaim,
            workQueue: workQueue
        )
    }

    func claim(
        creditExpiringAt expiry: Date,
        redeemRequestID: String,
        binding: CodexResetClaimBinding
    ) async -> ResetClaimOutcome {
        guard !Task.isCancelled, isCurrent(), requestState.activeRequestIDs.insert(redeemRequestID).inserted else {
            return bindingFailure()
        }
        defer { requestState.activeRequestIDs.remove(redeemRequestID) }
        guard let ticket = await workQueue.acquire("reset-credit") else { return .failed }
        defer { workQueue.finish(ticket) }
        if let previous = requestState.matchedCredits[redeemRequestID],
           previous.binding != binding || previous.expiry != expiry {
            return bindingFailure()
        }
        guard let initial = await loadCredential(for: binding, allowInteraction: true) else { return .failed }

        let creditID: String
        var confirmedExpiries: [Date]?
        if let previous = requestState.matchedCredits[redeemRequestID] {
            creditID = previous.creditID
        } else {
            let list: HTTPResponse
            do {
                list = try await usageClient.fetchResetCredits(
                    accessToken: initial.auth.tokens!.accessToken!, accountID: initial.auth.tokens?.accountID
                )
            } catch {
                AppDiagnostics.failure(.resetClaim, error: error, providerID: "codex",
                                       localContext: "Reset claim credit list request failed")
                return .failed
            }
            guard !Task.isCancelled, isCurrent() else { return bindingFailure() }
            guard (200..<300).contains(list.statusCode),
                  let body = (try? JSONSerialization.jsonObject(with: list.body)) as? [String: Any] else {
                return responseFailure(list, context: "credit list")
            }
            let selection = Self.creditSelection(in: body, expiringAt: expiry)
            switch selection {
            case .unknown:
                return responseFailure(list, context: "credit list")
            case .unavailable, .emptyInventory:
                onUnavailable?(
                    selection == .emptyInventory
                        ? .emptyInventory(binding: binding, selectedExpiry: expiry)
                        : .expiry(binding: binding, date: expiry))
                AppDiagnostics.record(.resetClaim, result: .success, category: .notAvailable, providerID: "codex")
                await refreshIfBound(to: binding, ticket: ticket)
                return .noCredit
            case .available(let id, let remaining):
                creditID = id
                if remaining != nil, var available = Self.availableCredits(in: body),
                    ProviderParse.number(body["available_count"]) == Double(available.count),
                    let index = available.firstIndex(where: { $0.id == id })
                {
                    available.remove(at: index)
                    confirmedExpiries = available.compactMap(\.expiry)
                }
                requestState.matchedCredits[redeemRequestID] = MatchedCredit(
                    binding: binding, expiry: expiry, creditID: id, remainingAtExpiry: remaining)
            }
        }

        // GET 대기 중의 재로그인·로그아웃 확인. 같은 출처·주체의 정상 토큰 회전만 허용.
        guard let current = await loadCredential(for: binding, allowInteraction: false), !Task.isCancelled, isCurrent() else { return .failed }
        let response: HTTPResponse
        do {
            response = try await usageClient.consumeResetCredit(
                accessToken: current.auth.tokens!.accessToken!, accountID: current.auth.tokens?.accountID,
                creditID: creditID, redeemRequestID: redeemRequestID
            )
        } catch {
            AppDiagnostics.failure(.resetClaim, error: error, providerID: "codex",
                                   localContext: "Reset claim consume request failed")
            return .failed
        }
        let result = Self.consumeResult(response)
        let outcome = result.outcome
        guard outcome != .failed else { return responseFailure(response, context: "consume") }
        AppDiagnostics.record(.resetClaim, result: .success, category: outcome == .success ? nil : .notAvailable,
                              providerID: "codex")
        if outcome == .success || outcome == .noCredit, let matched = requestState.matchedCredits[redeemRequestID],
            let onUnavailable
        {
            if result.alreadyRedeemed, matched.binding.verifiedAccountKey != nil {
                let expiries = await remainingExpiries(afterReplay: matched)
                onUnavailable(.replayed(matched, confirmedExpiries: expiries))
            } else {
                onUnavailable(
                    .credit(
                        matched,
                        confirmedExpiries: outcome == .success && !result.alreadyRedeemed ? confirmedExpiries : nil))
            }
        }
        await refreshIfBound(to: binding, ticket: ticket)
        return outcome
    }

    /// 재전송한 소비가 확인되면 원래 인증으로 남은 권의 만료 목록만 다시 조회.
    private func remainingExpiries(afterReplay credit: MatchedCredit) async -> [Date]? {
        do {
            guard !Task.isCancelled, isCurrent(), let login = try await credentialLoader(credit.binding.source, false),
                credit.binding.matches(login), !Task.isCancelled, isCurrent(),
                let token = login.auth.tokens?.accessToken
            else {
                AppDiagnostics.record(.resetCreditFetch, result: .degraded, category: .authInvalid, providerID: "codex")
                return nil
            }
            let response = try await usageClient.fetchResetCredits(
                accessToken: token, accountID: login.auth.tokens?.accountID)
            guard (200..<300).contains(response.statusCode) else {
                AppDiagnostics.record(
                    .resetCreditFetch, result: .degraded, category: .http(response.statusCode), providerID: "codex")
                return nil
            }
            guard let body = ProviderParse.jsonObject(response.body), let available = Self.availableCredits(in: body),
                ProviderParse.number(body["available_count"]) == Double(available.count),
                !available.contains(where: { $0.id == credit.creditID })
            else {
                AppDiagnostics.record(.resetCreditFetch, result: .degraded, category: .decoding, providerID: "codex")
                return nil
            }
            let dates = available.compactMap(\.expiry)
            guard dates.count == available.count else {
                AppDiagnostics.record(.resetCreditFetch, result: .degraded, category: .decoding, providerID: "codex")
                return nil
            }
            return dates
        } catch {
            AppDiagnostics.record(
                .resetCreditFetch, result: .degraded, providerID: "codex", error: error,
                localContext: "Post-replay credit inventory unavailable")
            return nil
        }
    }

    private func refreshIfBound(to binding: CodexResetClaimBinding, ticket: BackgroundWorkQueue.Ticket) async {
        // 완료된 요청의 인증만 재확인. 무관한 카탈로그 변경의 후속 조회 허용 여부는 router에서 판단.
        do {
            guard !Task.isCancelled,
                  let current = try await credentialLoader(binding.source, false),
                  binding.matches(current), !Task.isCancelled else {
                AppLog.info(LogTag.plugin("codex"), "post-claim refresh skipped: credential binding changed")
                AppDiagnostics.record(.postClaimRefresh, result: .bindingChanged, providerID: "codex")
                return
            }
            workQueue.finish(ticket)
            await refreshAfterClaim(binding)
        } catch {
            AppDiagnostics.failure(.postClaimRefresh, error: error, providerID: "codex",
                                   localContext: "Post-claim credential verification failed")
        }
    }

    private func loadCredential(for binding: CodexResetClaimBinding, allowInteraction: Bool) async -> CodexAuthState? {
        guard !Task.isCancelled, isCurrent() else {
            _ = bindingFailure()
            return nil
        }
        do {
            guard let state = try await credentialLoader(binding.source, allowInteraction) else {
                AppDiagnostics.record(.resetClaim, result: .failure, category: .notLoggedIn, providerID: "codex")
                return nil
            }
            guard !Task.isCancelled, isCurrent(), binding.matches(state) else {
                _ = bindingFailure()
                return nil
            }
            return state
        } catch {
            AppDiagnostics.failure(.resetClaim, error: error, providerID: "codex",
                                   localContext: "Reset claim credential read failed")
            return nil
        }
    }

    private func bindingFailure() -> ResetClaimOutcome {
        AppDiagnostics.record(.resetClaim, result: .failure, category: .authInvalid, providerID: "codex",
                              localContext: "Reset claim stopped because its account confirmation changed")
        return .failed
    }

    private func responseFailure(_ response: HTTPResponse, context: String) -> ResetClaimOutcome {
        AppDiagnostics.record(.resetClaim, result: .failure,
                              category: (200..<300).contains(response.statusCode) ? .decoding : .http(response.statusCode),
                              providerID: "codex", localContext: "Reset claim \(context) failed (HTTP \(response.statusCode))")
        return .failed
    }

    /// 같은 초의 권 중 원래 만료 시각 우선. 목록이 불완전하면 부재를 확정하지 않음.
    static func creditSelection(in body: [String: Any], expiringAt expiry: Date) -> CreditSelection {
        guard let available = availableCredits(in: body) else { return .unknown }
        if available.isEmpty, ProviderParse.number(body["available_count"]) == 0 { return .emptyInventory }
        let dated = available.compactMap { credit in credit.expiry.map { (expiry: $0, id: credit.id) } }
        let countMatches = body["available_count"].map { ProviderParse.number($0) == Double(available.count) } ?? true
        let complete = dated.count == available.count && countMatches
        let second = floor(expiry.timeIntervalSince1970)
        let matching = dated.filter { floor($0.expiry.timeIntervalSince1970) == second }
        let exact = matching.first { $0.expiry == expiry && $0.id != nil }
        if let id = exact?.id ?? matching.compactMap(\.id).first {
            return .available(id: id, remaining: complete ? matching.count - 1 : nil)
        }
        return matching.isEmpty && complete ? .unavailable : .unknown
    }

    private static func availableCredits(in body: [String: Any]) -> [(expiry: Date?, id: String?)]? {
        guard let credits = body["credits"] as? [[String: Any]] else {
            return body["credits"] == nil && ProviderParse.number(body["available_count"]) == 0 ? [] : nil
        }
        return credits.filter { ($0["status"] as? String ?? "available") == "available" }
            .map { (parseExpiry($0["expires_at"]), $0["id"] as? String) }
    }

    /// Consume 응답 → popover outcome. protocol code 4종 모두 HTTP 200으로 도착(outcome은 body의 `code`) — non-2xx·미인식 code는 `.failed`.
    static func outcome(fromConsume response: HTTPResponse) -> ResetClaimOutcome {
        consumeResult(response).outcome
    }

    private static func consumeResult(_ response: HTTPResponse) -> (outcome: ResetClaimOutcome, alreadyRedeemed: Bool) {
        guard (200..<300).contains(response.statusCode),
              let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let code = body["code"] as? String
        else {
            return (.failed, false)
        }
        switch code {
        case "reset": return (.success, false)
        case "already_redeemed": return (.success, true)
        case "nothing_to_reset": return (.nothingToReset, false)
        case "no_credit": return (.noCredit, false)
        default: return (.failed, false)
        }
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let string = value as? String, let date = EgasuISO8601.date(from: string) {
            return date
        }
        if let seconds = ProviderParse.number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}
