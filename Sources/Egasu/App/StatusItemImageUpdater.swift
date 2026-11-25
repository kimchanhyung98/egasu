import AppKit
import Observation

/// 메뉴 바 strip 렌더 loop (`StatusItemController`에서 분리): pinned-metric strip 렌더 + 참조 값 변경 시 재렌더.
/// `withObservationTracking`의 `onChange`는 one-shot이라 렌더마다 re-arm.
/// conceal 값 변경은 즉시 적용하고, 일반 UI 변경은 짧게 병합. 예측 deadline은 observable write 없이 1회 재렌더.
@MainActor
final class StatusItemImageUpdater {
    private let privacy: MenuBarPrivacyStore
    private let renderButtonImage: @MainActor (_ concealed: Bool) -> RenderedButtonImage
    private let delay: @MainActor () async -> Void
    private let deadlineDelay: @MainActor (Date) async -> Void
    private let apply: (NSImage) -> Void
    private var delayedUpdateTask: Task<Void, Never>?
    private var deadlineUpdateTask: Task<Void, Never>?

    /// - Parameter apply: 렌더된 image를 status-item button에 적용.
    convenience init(container: AppContainer, updater: UpdaterController, apply: @escaping (NSImage) -> Void) {
        self.init(
            privacy: container.privacy,
            renderButtonImage: { concealed in
                Self.renderButtonImage(container: container, updater: updater, concealed: concealed)
            },
            delay: { try? await Task.sleep(for: .milliseconds(50)) },
            apply: apply
        )
    }

    init(
        privacy: MenuBarPrivacyStore,
        renderButtonImage: @escaping @MainActor (_ concealed: Bool) -> RenderedButtonImage,
        delay: @escaping @MainActor () async -> Void,
        deadlineDelay: @escaping @MainActor (Date) async -> Void = { deadline in
            try? await Task.sleep(for: .seconds(max(deadline.timeIntervalSinceNow, 0)))
        },
        apply: @escaping (NSImage) -> Void
    ) {
        self.privacy = privacy
        self.renderButtonImage = renderButtonImage
        self.delay = delay
        self.deadlineDelay = deadlineDelay
        self.apply = apply
        privacy.setConcealUsageObserver { [weak self] concealed in
            self?.privacyDidChange(to: concealed)
        }
    }

    deinit {
        delayedUpdateTask?.cancel()
        deadlineUpdateTask?.cancel()
    }

    /// 즉시 렌더 + 다음 observable 변경에 re-arm.
    func update() {
        applyImmediately(concealed: privacy.concealUsage)
    }

    /// 소비된 observation의 대기 렌더는 병합·재등록, 미소비 구독은 유지하며 시간 기반 화면만 갱신.
    func deadlineDidFire() {
        if delayedUpdateTask != nil {
            applyImmediately(concealed: privacy.concealUsage)
        } else {
            applyRendered(renderButtonImage(privacy.concealUsage))
        }
    }

    private func privacyDidChange(to concealed: Bool) {
        applyImmediately(concealed: concealed)
    }

    private func applyImmediately(concealed: Bool) {
        delayedUpdateTask?.cancel()
        delayedUpdateTask = nil
        applyRendered(observeAndRender(concealed: concealed))
    }

    /// 모든 apply 경로가 경유 — 렌더마다 가장 가까운 deadline으로 예약을 교체.
    private func applyRendered(_ rendered: RenderedButtonImage) {
        scheduleDeadlineUpdate(at: rendered.nextInvalidation)
        apply(rendered.image)
    }

    private func observeAndRender(concealed: Bool? = nil) -> RenderedButtonImage {
        withObservationTracking {
            let currentConcealment = privacy.concealUsage
            return renderButtonImage(concealed ?? currentConcealment)
        } onChange: { [weak self] in
            // 일반 UI write는 저장 전 callback에서 렌더하지 않고 delay 뒤 최신 상태를 한 번 렌더.
            // 생산 관찰 대상은 모두 `@MainActor`; 동기 scheduling이 post-mutation privacy observer의 취소 순서 보장.
            MainActor.assumeIsolated {
                self?.scheduleDelayedUpdate()
            }
        }
    }

    private func scheduleDelayedUpdate() {
        delayedUpdateTask?.cancel()
        let delay = delay
        delayedUpdateTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            await delay()
            guard !Task.isCancelled, let self else { return }
            self.applyRendered(self.observeAndRender())
            self.delayedUpdateTask = nil
        }
    }

    /// 예측 deadline은 observable write 없이 도달 가능 — 가장 가까운 시각에만 1회 재렌더 예약.
    private func scheduleDeadlineUpdate(at deadline: Date?) {
        deadlineUpdateTask?.cancel()
        guard let deadline else {
            deadlineUpdateTask = nil
            return
        }
        let deadlineDelay = deadlineDelay
        deadlineUpdateTask = Task { @MainActor [weak self] in
            await deadlineDelay(deadline)
            guard !Task.isCancelled else { return }
            self?.deadlineDidFire()
        }
    }

    /// 메뉴 막대에 표시할 지표가 없거나 사용량을 가리면 앱 아이콘 표시.
    private static func renderButtonImage(container: AppContainer, updater: UpdaterController, concealed: Bool)
        -> RenderedButtonImage
    {
        let settings = container.dataStore.displaySettings
        let showsExtras = settings.showsMenuBarExtras
        let updateAvailable = showsExtras && updater.availableUpdateVersion != nil
        let limit: MenuBarLimit = concealed ? .iconOnly : settings.menuBarLimit
        guard limit != .iconOnly else {
            return RenderedButtonImage(
                image: updateAvailable ? MenuBarStripRenderer.appIconWithUpdateDot : MenuBarStripRenderer.appIcon,
                nextInvalidation: nil
            )
        }
        let now = Date()
        let accounts = container.dashboardAccounts()
        let board = container.dataStore.priorityBoard(accounts: accounts, pinned: container.layout.priorityPinIDs, now: now)
        var content = MenuBarContentBuilder.build(
            board: board, limit: limit, selection: settings.menuBarSelection,
            multiAccountFamilies: MenuBarContentBuilder.multiAccountFamilies(accounts), style: settings.menuBarStyle,
            showResetCountdown: settings.showsMenuBarResetCountdown, now: now
        )
        content.updateAvailable = updateAvailable
        content = content.showingExtraIndicators(showsExtras)
        return RenderedButtonImage(
            image: MenuBarStripRenderer.image(for: content, style: settings.menuBarStyle) ?? MenuBarStripRenderer.appIcon,
            nextInvalidation: content.nextInvalidation
        )
    }


    /// 렌더 결과 + 현재 strip 값이 시간만으로 무효화되는 가장 이른 시각.
    struct RenderedButtonImage {
        let image: NSImage
        let nextInvalidation: Date?
    }
}
