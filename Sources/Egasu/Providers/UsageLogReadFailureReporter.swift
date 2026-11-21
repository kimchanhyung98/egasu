import Foundation

/// 로컬 사용량 파일의 새 읽기 실패만 로그. 복구 후 다시 실패하면 재보고.
actor UsageLogReadFailureReporter {
    typealias Warning = @Sendable (Int) -> Void

    private var failingPaths: Set<String> = []
    private let warning: Warning?
    private let logTag: String
    private let provider: String?

    init(logTag: String, warning: Warning? = nil) {
        self.logTag = logTag
        self.provider = logTag.split(separator: ":").last.flatMap { TelemetryPrivacy.providerFamily(String($0)) }
        self.warning = warning
    }

    /// 새로 실패한 경로 반환. 호출자는 경로별 상세 로그를 실패 발생당 한 번 기록 가능.
    @discardableResult
    func update(checkedPaths: Set<String>, failingPaths nextFailingPaths: Set<String>) -> Set<String> {
        let previouslyFailed = !failingPaths.isEmpty
        let newlyFailing = nextFailingPaths.subtracting(failingPaths)
        // 같은 경로를 다시 읽어 성공한 경우에만 실패 상태 해제. 다른 파일의 조회로 해제 금지.
        failingPaths.subtract(checkedPaths)
        failingPaths.formUnion(nextFailingPaths)
        if previouslyFailed, failingPaths.isEmpty {
            AppDiagnostics.record(.historyScan, result: .success, providerID: provider)
        }
        guard !newlyFailing.isEmpty else { return [] }
        let count = newlyFailing.count
        let noun = count == 1 ? "file" : "files"
        AppDiagnostics.record(.historyScan, result: .degraded, category: .storage, providerID: provider,
                              localContext: "source=\(logTag); Could not read \(count) local usage log \(noun); skipped for this refresh")
        warning?(count)
        return newlyFailing
    }
}
