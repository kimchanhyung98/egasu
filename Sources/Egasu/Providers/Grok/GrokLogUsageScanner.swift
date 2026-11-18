import Foundation

/// Grok CLI 로컬 기록의 일별 토큰 집계와 비용 추정.
/// 토큰 행에 모델 ID가 없어 프로세스·세션별 모델 적용 이벤트로 귀속.
/// 집계 결과를 공통 일별 사용량 형식으로 반환.
struct GrokLogUsageScanner: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL
    private let readFailureReporter: UsageLogReadFailureReporter
    private let numericFailureReporter = NumericFailureReporter()

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        readFailureWarning: UsageLogReadFailureReporter.Warning? = nil
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.readFailureReporter = UsageLogReadFailureReporter(
            logTag: LogTag.plugin("grok"),
            warning: readFailureWarning
        )
    }

    /// `~/.grok/logs/unified.jsonl` — `$GROK_HOME` 설정 시 `$GROK_HOME/logs/unified.jsonl`.
    var logPath: String {
        if let raw = environment.value(for: "GROK_HOME")?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return expandHome(raw).trimmingTrailingSlashes + "/logs/unified.jsonl"
        }
        return homeDirectory().appendingPathComponent(".grok/logs/unified.jsonl").path
    }

    /// 완료 턴 원장과 로그의 최근 `daysBack`일 스캔.
    /// 입력 부재·취소는 `nil`, 읽기 실패는 실패 수로 보존. 유효 행이 없으면 빈 `daily`.
    /// nonisolated async — `@MainActor` provider가 `await`하면 파일 읽기+parse가 main actor 밖에서 수행.
    func scan(daysBack: Int = 30, now: Date = Date(), pricing: ModelPricing) async -> LogUsageScan? {
        guard !Task.isCancelled else { return nil }
        let path = logPath
        let since = JSONLScanning.sinceDate(daysBack: daysBack, now: now)
        let sessions = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("sessions", isDirectory: true)
        guard let sessionUsage = GrokSessionUsageScanner(files: files).collect(root: sessions, since: since, until: now),
              !Task.isCancelled else { return nil }
        var sessionScan = UsageHistoryBuilder.scan(
            sessionUsage.collection, providerID: "grok", since: since, until: now,
            pricing: pricing, allowEstimates: false
        )
        sessionScan?.rejectedMetadataRows += sessionUsage.incompleteRows
        guard files.exists(path) else { return sessionScan }
        let text: String
        do {
            text = try files.readText(path)
            guard !Task.isCancelled else { return nil }
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [])
        } catch is CancellationError {
            return nil
        } catch {
            guard !Task.isCancelled else { return nil }
            await readFailureReporter.update(checkedPaths: [path], failingPaths: [path])
            guard !Task.isCancelled else { return nil }
            return DailyUsageAccumulator.merged([
                sessionScan, DailyUsageAccumulator().build(source: "grok", readFailureCount: 1)
            ])
        }
        guard !Task.isCancelled else { return nil }
        let scan = Self.parse(text, since: since, pricing: pricing,
                              excludingSessionIDs: sessionUsage.preferredSessionIDs, reportNumericFailures: false)
        guard !Task.isCancelled else { return nil }
        await numericFailureReporter.update(path: path, rejectedRows: scan.rejectedNumericRows)
        return Task.isCancelled ? nil : DailyUsageAccumulator.merged([sessionScan, scan])
    }

    /// 추가 기록 방식의 로그를 시간순으로 한 번 순회.
    /// 조회 기간 이전의 모델 변경도 프로세스·세션 귀속에 반영.
    static func parse(
        _ text: String, since: Date, pricing: ModelPricing,
        excludingSessionIDs: Set<String> = [], reportNumericFailures: Bool = true,
        onLine: (() -> Void)? = nil
    ) -> LogUsageScan {
        var modelByPID: [Int: ModelContext] = [:]
        var modelBySession: [SessionKey: ModelContext] = [:]
        var inheritedSessions: Set<SessionKey> = []
        var ambiguousPIDs: Set<Int> = []
        var accumulator = DailyUsageAccumulator()
        var rejectedMetadataRows = 0

        text.enumerateLines { line, stop in
            onLine?()
            guard !Task.isCancelled else { stop = true; return }
            guard line.contains("inference_done") || line.contains("model")
                    || line.contains("process resource limits") else { return }
            guard let data = line.data(using: .utf8),
                  let object = ProviderParse.jsonObject(data),
                  let msg = object["msg"] as? String
            else { return }

            let ctx = object["ctx"] as? [String: Any] ?? [:]
            let pid = UsageLogNumbers.count(object["pid"]).flatMap { $0 > 0 ? $0 : nil }
            let sid = (object["sid"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let session = pid.flatMap { pid in sid.map { SessionKey(pid: pid, sid: $0) } }

            // 시작 이벤트는 프로세스당 한 번 기록. PID 재사용 시 이전 실행의 모델 상태만 제거.
            if msg == "process resource limits", let pid {
                modelByPID.removeValue(forKey: pid)
                modelBySession = modelBySession.filter { $0.key.pid != pid }
                inheritedSessions = inheritedSessions.filter { $0.pid != pid }
                ambiguousPIDs.remove(pid)
                return
            }

            // 세션 ID 없는 하위 에이전트 모델 이벤트 이후에는 프로세스 기본 모델의 갱신·추정 사용 중단.
            if msg == "subagent model resolved", sid == nil {
                if let pid { ambiguousPIDs.insert(pid) }
                return
            }

            if let model = modelContext(msg: msg, ctx: ctx) {
                if let session {
                    modelBySession[session] = model
                } else if let pid, !ambiguousPIDs.contains(pid) {
                    modelByPID[pid] = model
                }
                return
            }

            guard msg == "shell.turn.inference_done" else { return }
            if let sid, excludingSessionIDs.contains(sid) { return }
            let model: ModelContext?
            if let session {
                if let sessionModel = modelBySession[session] {
                    model = sessionModel
                } else if inheritedSessions.contains(session) || !ambiguousPIDs.contains(session.pid) {
                    model = modelByPID[session.pid]
                    if model != nil { inheritedSessions.insert(session) }
                } else {
                    model = nil
                }
            } else {
                model = pid.flatMap { ambiguousPIDs.contains($0) ? nil : modelByPID[$0] }
            }
            guard ctx["prompt_tokens"] != nil,
                  !["prompt_tokens", "cached_prompt_tokens", "completion_tokens", "reasoning_tokens"].allSatisfy({
                      ctx[$0] == nil || ctx[$0] is NSNull
                  }),
                  let timestamp = (object["ts"] as? String).flatMap(EgasuISO8601.date(from:)),
                  timestamp >= since
            else { return }

            guard object["pid"] == nil || pid != nil,
                  let promptTokens = UsageLogNumbers.count(ctx["prompt_tokens"]),
                  let completion = UsageLogNumbers.count(ctx["completion_tokens"], missing: 0),
                  let reasoning = UsageLogNumbers.count(ctx["reasoning_tokens"], missing: 0),
                  let cached = UsageLogNumbers.count(ctx["cached_prompt_tokens"], missing: 0),
                  let output = UsageLogNumbers.sum(completion, model?.outputIncludesReasoning == true ? 0 : reasoning),
                  let totalTokens = UsageLogNumbers.sum(promptTokens, output)
            else {
                accumulator.rejectNumericRow()
                return
            }
            // `cached_prompt_tokens`는 `prompt_tokens`의 부분집합. 입력 토큰 중복 합산 금지.
            let cacheRead = min(cached, promptTokens)
            let inputNoCache = promptTokens - cacheRead

            let day = DailyUsageAccumulator.dayKey(from: timestamp)

            // 원장과 중복 여부를 판별할 수 없는 세션 없는 로그는 보류.
            if !excludingSessionIDs.isEmpty, sid == nil {
                if totalTokens > 0 { rejectedMetadataRows += 1 }
                return
            }
            // 모델 미귀속 행은 제외. 가격 없는 모델의 실측 토큰은 유지하고 기간 비용은 생략.
            guard let model = model?.model else {
                if totalTokens > 0, session != nil || pid.map({ ambiguousPIDs.contains($0) }) == true {
                    rejectedMetadataRows += 1
                }
                return
            }
            let tokenBreakdown = TokenBreakdown(input: inputNoCache, cacheRead: cacheRead, output: output)
            let cost = pricing.estimatedCostDollars(model: model, tokens: tokenBreakdown)
            if cost == nil, totalTokens > 0 {
                accumulator.addUnknownModel(day: day, model: model)
            }
            accumulator.add(day: day, tokens: totalTokens, cost: cost, model: model)
        }

        if !Task.isCancelled, rejectedMetadataRows > 0 {
            AppDiagnostics.record(
                .historyScan, result: .degraded, category: .decoding, providerID: "grok",
                localContext: "source=grok; unattributed_session_rows=\(rejectedMetadataRows)"
            )
        }
        return accumulator.build(
            source: "grok", reportNumericFailures: reportNumericFailures, rejectedMetadataRows: rejectedMetadataRows
        )
    }

    private struct SessionKey: Hashable {
        let pid: Int
        let sid: String
    }

    /// 모델 적용 시점의 API 계산 방식 — Responses 출력 토큰은 추론 포함.
    private struct ModelContext {
        let model: String
        let outputIncludesReasoning: Bool
    }

    /// 같은 파일의 손상 행 수 증가분만 보고. 손상 없는 조회 결과에서는 복구 기록.
    private actor NumericFailureReporter {
        private var rejectedRowsByPath: [String: Int] = [:]

        func update(path: String, rejectedRows: Int) {
            let previous = rejectedRowsByPath[path] ?? 0
            if rejectedRows == 0 {
                rejectedRowsByPath.removeValue(forKey: path)
                if previous > 0 { AppDiagnostics.record(.historyScan, result: .success, providerID: "grok") }
            } else {
                rejectedRowsByPath[path] = rejectedRows
                if rejectedRows > previous { UsageLogNumbers.reportRejectedRows(rejectedRows - previous, source: "grok") }
            }
        }
    }

    /// 실제 모델 적용 이벤트의 모델·API 계산 방식. 검증 전 요청인 `model changed`는 제외.
    /// 세션 구분은 호출부 담당. 여기서는 모델·API 필드만 해석.
    private static func modelContext(msg: String, ctx: [String: Any]) -> ModelContext? {
        let raw: Any?
        switch msg {
        case "model catalog: notifying clients":
            raw = ctx["current_model_id"]
        case "backend_search: model switch":
            raw = ctx["new_model"] ?? ctx["model"] ?? ctx["current_model_id"] ?? ctx["model_id"]
        case "subagent model resolved":
            raw = ctx["child_model"] ?? ctx["model_id"] ?? ctx["model"]
        default:
            return nil
        }
        guard let model = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty
        else { return nil }
        return ModelContext(model: model, outputIncludesReasoning: ctx["api_backend"] as? String == "Responses")
    }

}
