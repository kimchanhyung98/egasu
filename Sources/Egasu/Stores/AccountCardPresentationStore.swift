import Foundation
import Observation

enum AccountCardDisplayMode: String, CaseIterable, Sendable {
    case singleCard
    case separateCards

    var label: String {
        switch self {
        case .singleCard: "Single Card"
        case .separateCards: "Separate Cards"
        }
    }
}

/// 등록 계정의 프로바이더별 표시 순서 — 인증·계정 목록·레이아웃과 독립.
@MainActor
@Observable
final class AccountCardPresentationStore {
    static let storageKey = "openusage.accountCardPresentation.v1"

    private struct Settings: Codable, Equatable {
        var profileOrderByFamily: [String: [String]] = [:]
        // 이전 버전도 이 JSON을 읽을 수 있도록 구형 카드 모드 필드의 저장 형식을 유지.
        private var legacyModesByFamily: [String: String] = [:]

        private enum CodingKeys: String, CodingKey {
            case profileOrderByFamily
            case legacyModesByFamily = "modesByFamily"
        }

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            profileOrderByFamily = try values.decode([String: [String]].self, forKey: .profileOrderByFamily)
            legacyModesByFamily = (try? values.decode([String: String].self, forKey: .legacyModesByFamily)) ?? [:]
        }
    }

    private let defaults: UserDefaults
    private var settings = Settings()
    private var hasUnreadableSettings = false
    private(set) var errorMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.object(forKey: Self.storageKey) {
            do {
                guard let data = raw as? Data else { throw CocoaError(.coderReadCorrupt) }
                settings = try JSONDecoder().decode(Settings.self, from: data)
            } catch {
                hasUnreadableSettings = true
                errorMessage = L10n.errors(
                    "egasu couldn't read the saved account display settings. They were left unchanged. Restart egasu and check the log before trying again."
                )
                AppLog.error(.config, "account-card presentation was unreadable; preserving it and blocking writes: \(error.localizedDescription)")
            }
        }
    }

    /// 읽기는 저장 순서를 정리하지 않음 — 일시적 registry·runtime 누락 뒤에도 기존 순서 복원.
    func orderedProfiles(_ profiles: [AccountProfile], family: String) -> [AccountProfile] {
        guard AccountProfilesStore.isSupportedFamily(family) else { return [] }
        let registered = profiles.enumerated()
            .filter { $0.element.family == family && !$0.element.isArchived }
            .sorted {
                if $0.element.createdAt == $1.element.createdAt { return $0.offset < $1.offset }
                return $0.element.createdAt < $1.element.createdAt
            }
            .map(\.element)
        let byID = Dictionary(uniqueKeysWithValues: registered.map { ($0.id, $0) })
        var seen = Set<String>()
        let saved = (settings.profileOrderByFamily[family] ?? []).compactMap { id -> AccountProfile? in
            guard let profile = byID[id], seen.insert(id).inserted else { return nil }
            return profile
        }
        return saved + registered.filter { !seen.contains($0.id) }
    }

    @discardableResult
    func reorder(dragged: String, target: String, family: String, profiles: [AccountProfile]) -> Bool {
        guard !hasUnreadableSettings else { return false }
        let ids = orderedProfiles(profiles, family: family).map(\.id)
        guard let next = LayoutStore.reordered(ids, dragged: dragged, target: target) else { return false }
        var updated = settings
        updated.profileOrderByFamily[family] = next
        return persist(updated)
    }

    private func persist(_ updated: Settings) -> Bool {
        guard !hasUnreadableSettings, updated != settings else { return false }
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: Self.storageKey)
            settings = updated
            errorMessage = nil
            return true
        } catch {
            errorMessage = L10n.errors("egasu couldn't save the account display settings. Try again and check the app log.")
            AppLog.error(.config, "failed to encode account-card presentation: \(error.localizedDescription)")
            return false
        }
    }
}
