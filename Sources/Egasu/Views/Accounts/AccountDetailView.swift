import SwiftUI

/// 계정 상세 — 계정별 지표·공통 지표 설정과 계정 관리 블록.
struct AccountDetailView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(PopoverState.self) private var popover
    let accountID: String
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let rowFrames: [String: CGRect]

    var body: some View {
        if let provider = container.accountManagementProvider(id: accountID) {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                if let problem = dataStore.headerNotice(for: accountID) {
                    ProblemCard(message: problem)
                }
                AccountMetricSettingsCard(
                    title: L10n.accounts("Account Settings"),
                    metrics: layout.accountSettingsMetrics(for: accountID),
                    reorderSpaceName: reorderSpaceName,
                    reorderLift: $reorderLift,
                    rowFrames: rowFrames
                )
                AccountMetricSettingsCard(
                    title: L10n.accounts("Shared Settings"),
                    metrics: layout.sharedSettingsMetrics(for: accountID),
                    reorderSpaceName: reorderSpaceName,
                    reorderLift: $reorderLift,
                    rowFrames: rowFrames
                )
                if let profile = registeredProfile {
                    RegisteredAccountRows(profile: profile, onRemoved: backToList)
                } else {
                    ProviderAccountRows(
                        provider: provider,
                        keyProvider: container.apiKeyProviders.first { $0.provider.id == accountID },
                        onRemoved: backToList
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Claude·Codex 등록 계정 — 이름·전환·다시 로그인·삭제를 계정 단위로 관리.
    private var registeredProfile: AccountProfile? {
        container.accountProfileID(for: accountID).flatMap { container.accountProfiles.profile(id: $0) }
    }

    private func backToList() {
        withAnimation(Motion.navigation) { popover.accountDetailID = nil }
    }
}

/// 한 설정 그룹의 지표 카드 — 표시·고정과 그룹 안 순서 변경.
struct AccountMetricSettingsCard: View {
    @Environment(LayoutStore.self) private var layout
    let title: String
    let metrics: [WidgetDescriptor]
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let rowFrames: [String: CGRect]

    @State private var activeMetricID: String?

    var body: some View {
        if !metrics.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(title)
                    Spacer(minLength: 8)
                }
                .accountActionRowPadding()
                ForEach(metrics, id: \.id) { metric in
                    metricRow(metric)
                }
            }
            .cardSurface()
        }
    }

    private func metricRow(_ metric: WidgetDescriptor) -> some View {
        AccountMetricRow(
            title: L10n.metrics(metric.title),
            isPinnable: metric.pinnable,
            isShown: Binding(
                get: { layout.isMetricEnabled(metric.id) },
                set: { layout.setMetricEnabled(metric.id, $0) }
            ),
            isPinned: Binding(
                get: { layout.isPinned(metric.id) },
                set: { pinned in
                    if pinned && !layout.canPin(metric.id) {
                        layout.notePinDenied(metric.id)
                    } else {
                        layout.setPinned(pinned, for: metric.id)
                    }
                }
            ),
            grip: { ReorderGrip().highPriorityGesture(metricDragGesture(for: metric)) }
        )
        .opacity(activeMetricID == metric.id ? 0 : 1)
        .reorderFrame(id: metric.id, in: .named(reorderSpaceName))
    }

    private func metricDragGesture(for metric: WidgetDescriptor) -> some Gesture {
        reorderDragGesture(
            id: metric.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { value in
                let preview = AccountMetricRow(
                    title: L10n.metrics(metric.title),
                    isPinnable: metric.pinnable,
                    isShown: .constant(layout.isMetricEnabled(metric.id)),
                    isPinned: .constant(layout.isPinned(metric.id))
                ) { ReorderGrip() }
                .liftedRowSurface()
                return ReorderLift.make(
                    id: metric.id, payload: .view(AnyView(preview)), value: value, frames: rowFrames)
            },
            orderedIDs: { metrics.map(\.id) },
            reorder: {
                layout.reorderMetric(
                    dragged: metric.id, target: $0, in: metric.providerID, preservingExpandedMembership: true)
            }
        )
    }
}

/// 지표 한 행 — 기존 메뉴 막대 고정은 표시 여부와 독립, 고정할 수 없는 지표는 자리만 유지.
struct AccountMetricRow<Grip: View>: View {
    let title: String
    let isPinnable: Bool
    @Binding var isShown: Bool
    @Binding var isPinned: Bool
    @ViewBuilder var grip: Grip

    var body: some View {
        HStack(spacing: 10) {
            grip
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            pinButton
            Toggle(title, isOn: $isShown)
                .labelsHidden()
                .settingsSwitchStyle()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
    }

    @ViewBuilder
    private var pinButton: some View {
        if isPinnable {
            Button {
                isPinned.toggle()
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isPinned ? .secondary : .tertiary)
                    .frame(width: 16, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPinned ? L10n.accounts("Unpin %@", title) : L10n.accounts("Pin %@", title))
        } else {
            Color.clear.frame(width: 16, height: 22)
        }
    }
}

/// 계정에 손볼 일이 있을 때 맨 위 카드.
struct ProblemCard: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.notice)
        }
        .font(.system(size: 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardSurface()
    }
}

/// 등록 계정 이외의 계정 관리 — API 키 교체와 "Remove Account…" 제공.
/// 감지형은 추적만 끄고 로그인은 그대로, API 키형은 앱이 저장한 키만 지우고 끔(환경 변수 키는 그대로).
struct ProviderAccountRows: View {
    let provider: Provider
    let keyProvider: (any APIKeyManaging)?
    let onRemoved: () -> Void

    @Environment(AppContainer.self) private var container
    @State private var isConfirming = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(spacing: 0) {
                if let keyProvider {
                    APIKeyRows(provider: keyProvider)
                }
                Button(role: .destructive) {
                    isConfirming = true
                } label: {
                    Text(L10n.accounts("Remove Account…"))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accountActionRowPadding()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .confirmationDialog(
                    L10n.accounts("Remove %@?", container.displayName(for: provider)),
                    isPresented: $isConfirming,
                    titleVisibility: .visible
                ) {
                    Button(L10n.accounts("Remove Account"), role: .destructive, action: remove)
                    Button(L10n.accounts("Cancel"), role: .cancel) {}
                } message: {
                    Text(
                        keyProvider == nil
                            ? L10n.accounts(
                                "egasu stops tracking this account. Your %@ sign-in stays as it is.",
                                provider.displayName)
                            : L10n.accounts(
                                "egasu deletes the API key it saved and stops tracking this account. Keys in your environment stay as they are."
                            ))
                }
            }
            .cardSurface()
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .padding(.horizontal, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func remove() {
        do {
            try Self.remove(providerID: provider.id, keyProvider: keyProvider) {
                container.setProviderEnabled($0, for: $1)
            }
        } catch {
            AppLog.error(.auth, "API key delete failed for \(provider.id): \(error.localizedDescription)")
            self.error = UserFacingErrors.message(error)
            return
        }
        onRemoved()
    }

    /// 앱이 저장한 키만 지우고(환경 변수 키는 그대로) 추적을 끔 — 로컬 로그인 파일은 건드리지 않음.
    /// 키 삭제가 실패하면 끄지 않음(재시도 가능).
    static func remove(
        providerID: String,
        keyProvider: (any APIKeyManaging)?,
        setEnabled: (Bool, String) -> Void
    ) throws {
        if let keyProvider, [.saved, .overrideActive].contains(keyProvider.apiKeyStatus) {
            try keyProvider.deleteAPIKey()
        }
        setEnabled(false, providerID)
    }
}
