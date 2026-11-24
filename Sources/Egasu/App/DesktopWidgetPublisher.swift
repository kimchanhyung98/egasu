import DesktopWidgetSupport
import Foundation
import Observation
import WidgetKit

/// 메인 액터의 표시 상태를 관찰하고 공유 파일 교체가 끝난 뒤 위젯 갱신 요청.
@MainActor
final class DesktopWidgetPublisher {
    private let content: @MainActor () -> DesktopWidgetContent
    private let publish: @Sendable (DesktopWidgetContent) -> Void
    private let queue = DispatchQueue(label: "egasu.desktop-widget.write", qos: .utility)
    private var defaultsObserver: NSObjectProtocol?
    private var timeFormat = TimeFormatSetting.current
    private var stopped = false

    static func start(for container: AppContainer) -> DesktopWidgetPublisher? {
        guard Bundle.main.object(forInfoDictionaryKey: "EgasuWidgetAppGroup") is String else { return nil }
        let store = DesktopWidgetStore()
        return DesktopWidgetPublisher(content: { container.desktopWidgetContent() }) { content in
            do {
                if try store.write(content) {
                    WidgetCenter.shared.reloadTimelines(ofKind: DesktopWidgetStore.kind)
                }
            } catch {
                AppLog.error(.cache, "Desktop widget update failed: \(AppLog.errorDetails(error))")
            }
        }
    }

    init(
        content: @escaping @MainActor () -> DesktopWidgetContent,
        publish: @escaping @Sendable (DesktopWidgetContent) -> Void
    ) {
        self.content = content
        self.publish = publish
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshTimeFormat() }
        }
        observe()
    }

    private func observe() {
        guard !stopped else { return }
        let latest = withObservationTracking {
            content()
        } onChange: { [weak self] in
            // willSet에서 관찰이 해제되므로 현재 변경이 끝난 다음 턴에 최신 상태로 재등록.
            Task { @MainActor [weak self] in self?.observe() }
        }
        enqueue(latest)
    }

    private func refreshTimeFormat() {
        let current = TimeFormatSetting.current
        guard current != timeFormat, !stopped else { return }
        timeFormat = current
        enqueue(content())
    }

    private func enqueue(_ latest: DesktopWidgetContent) {
        queue.async { [publish] in publish(latest) }
    }

    /// 종료 직전 계정 삭제·개인정보 보호 변경도 마지막 파일에 반영.
    func finish() {
        guard !stopped else { return }
        stopped = true
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
        let latest = content()
        queue.sync { publish(latest) }
    }
}
