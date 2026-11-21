import Foundation

/// All Usage 카드 단위 — 프로바이더 1개와 그 계정 섹션들.
struct DashboardFamily: Identifiable {
    let id: String
    let provider: Provider
    /// 카드 머리글 이름 — 계정명 없는 프로바이더 표시명.
    let displayName: String
    var accounts: [DashboardAccount]

    func isVisible(headerNotice: (String) -> String?) -> Bool {
        accounts.contains { $0.isVisible(headerNotice: headerNotice) }
    }

    /// 공유 이미지에서 이메일 계정명과 마지막 초기화권 사용 후 임시 유지한 행을 제외한 사본.
    var forSharing: DashboardFamily {
        var copy = self
        copy.accounts = accounts.map(\.forSharing)
        return copy
    }
}

/// 계정 섹션 — 카드 ID 하나와 표시 행.
struct DashboardAccount: Identifiable {
    let provider: Provider
    /// 프로바이더 표시명 — 계정명이 없을 때 대신 보이는 이름.
    let providerName: String
    /// 캡션·Priority 둘째 줄 계정명 — nil이면 생략.
    private(set) var name: String?
    /// 계정명을 눌러 바꿔 보는 로그인 이메일 — 계정명과 다를 때만, 공유 이미지에서는 제외.
    var email: String? = nil
    var isInUse = false
    private(set) var lines: [DashboardLine]
    /// 첫 수신 전 대기 모양으로 표시할 지표.
    var waitingMetricIDs: [String] = []

    /// 모든 표시 경로에서 데이터 없는 한도·값 행을 제외하고 나머지 순서 유지.
    init(
        provider: Provider, providerName: String, name: String?, email: String? = nil,
        isInUse: Bool = false, lines: [DashboardLine], waitingMetricIDs: [String] = [],
        retainingResetClaims: [String: CodexResetClaimBinding] = [:]
    ) {
        self.provider = provider
        self.providerName = providerName
        self.name = name
        self.email = email
        self.isInUse = isInUse
        self.lines = lines.filter { line in
            if line.isVisible { return true }
            guard line.data.showsResetExpiries, line.data.hasData,
                let binding = retainingResetClaims[line.id]
            else { return false }
            return binding == line.data.codexResetClaimBinding
        }
        self.waitingMetricIDs = waitingMetricIDs
    }

    var id: String { provider.id }
    func isVisible(headerNotice: (String) -> String?) -> Bool {
        !lines.isEmpty || !waitingMetricIDs.isEmpty || headerNotice(id) != nil
    }

    var isNamedByEmail: Bool { name?.contains("@") ?? false }
    /// Priority 둘째 줄 — 계정명, 없으면 프로바이더 표시명.
    var subtitle: String { name ?? providerName }
    /// 접근성 이름 — "Codex — Account 1".
    var fullName: String { name.map { "\(providerName) — \($0)" } ?? providerName }

    var hidingEmail: DashboardAccount {
        var copy = self
        copy.email = nil
        if isNamedByEmail { copy.name = nil }
        return copy
    }

    fileprivate var forSharing: DashboardAccount {
        var copy = hidingEmail
        copy.lines.removeAll { !$0.isVisible }
        return copy
    }

    /// 이메일 보기 — 계정명 자리에 로그인 이메일, 이메일이 없으면 그대로.
    var showingEmail: DashboardAccount {
        guard let email else { return self }
        var copy = self
        copy.name = email
        return copy
    }
}

/// 지표 행 — 데이터 없는 한도·값 행은 숨기고 기간·차트 행은 "No data"로 유지.
struct DashboardLine: Identifiable {
    let descriptor: WidgetDescriptor
    let data: WidgetData
    var id: String { descriptor.id }

    var isVisible: Bool {
        if data.showsResetExpiries { return data.hasData && data.resetCreditCount > 0 }
        return data.hasData || data.isUsagePeriod || data.isChart
    }
}
