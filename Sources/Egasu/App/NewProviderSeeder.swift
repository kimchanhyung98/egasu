import Foundation

/// 업데이트로 추가된 프로바이더 중 로컬 탐지에 성공한 항목만 자동 활성화.
/// 새 ID만 탐지하여 이미 확인한 프로바이더의 비활성화 선택 보존.
/// 탐지 완료 후 새 ID 기록 — 취소된 탐지는 다음 실행에서 재시도.
@MainActor
enum NewProviderSeeder {
    /// 탐지 작업을 시작한 경우에만 작업 핸들 반환.
    @discardableResult
    static func reconcileIfNeeded(
        providers: [ProviderRuntime],
        enablement: ProviderEnablementStore,
        workQueue: BackgroundWorkQueue = BackgroundWorkQueue()
    ) -> Task<Void, Never>? {
        guard enablement.enabledIDs != nil, !enablement.isInitialDetectionPending else { return nil }

        let currentIDs = Set(providers.map(\.provider.id))
        // 알려진 목록이 없으면 새 항목과 사용자 비활성화를 구분할 수 없으므로 현재 목록만 기준값으로 저장.
        guard !enablement.knownIDs.isEmpty else {
            enablement.registerKnownProviders(currentIDs)
            return nil
        }

        let newIDs = currentIDs.subtracting(enablement.knownIDs)
        guard !newIDs.isEmpty else { return nil }
        AppLog.info(.config, "new providers since last run: \(newIDs.sorted()); probing local credentials")

        return Task {
            // 첫 실행과 같은 순차 로컬 탐지 수행.
            let newProviders = providers.filter { newIDs.contains($0.provider.id) }
            let detected = await FirstRunSeeder.detectLocalProviders(newProviders, workQueue: workQueue)
            guard !Task.isCancelled else { return }
            enablement.registerKnownProviders(newIDs)
            for id in detected.sorted() {
                // 탐지 중 사용자가 이미 활성화한 항목은 유지.
                guard !enablement.isEnabled(id) else { continue }
                AppLog.info(.config, "new provider \(id): credentials detected, enabling")
                enablement.setEnabled(true, for: id)
            }
        }
    }
}
