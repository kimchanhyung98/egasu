import SwiftUI

/// API 키 관리 행 — 교체 버튼을 누르면 입력란과 Cancel·Save 버튼 표시.
/// 키를 인증 저장소의 설정 파일에 저장하여 환경 변수보다 우선 적용 — 저장 직후 새로 고침.
/// 인증 실패는 문제 카드에 표시 — 저장 키의 가림 해제 기능은 제공하지 않음.
struct APIKeyRows: View {
    let provider: any APIKeyManaging
    @Environment(WidgetDataStore.self) private var dataStore

    @State private var status: APIKeyStatus = .notSet
    @State private var isEditing = false
    @State private var input = ""
    @State private var error: String?
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.customize("API Key"))
                Spacer(minLength: 8)
                Text(Self.statusLabel(status))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .accountActionRowPadding()

            if isEditing {
                editor
            } else {
                Button {
                    error = nil
                    isEditing = true
                    isFieldFocused = true
                } label: {
                    Text(L10n.accounts(status == .notSet ? "Add API Key…" : "Replace API Key…"))
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accountActionRowPadding()
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, PanelMetrics.controlRowPadding)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { status = provider.apiKeyStatus }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            SecureField(L10n.accounts("New API Key"), text: $input)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .onSubmit(save)
            HStack(spacing: 8) {
                Button(L10n.customize("Cancel")) {
                    input = ""
                    isEditing = false
                }
                Button(L10n.customize("Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedInput.isEmpty)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
    }

    private var trimmedInput: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }

    static func statusLabel(_ status: APIKeyStatus) -> String {
        switch status {
        case .notSet: L10n.accounts("Not Set")
        case .fromEnvironment: L10n.customize("From Your Environment")
        case .saved: L10n.customize("Saved in App")
        case .overrideActive: L10n.customize("Custom Key")
        }
    }

    private func save() {
        let key = trimmedInput
        guard !key.isEmpty else { return }
        do {
            try provider.saveAPIKey(key)
            input = ""
            isEditing = false
            error = nil
            status = provider.apiKeyStatus
            refreshAfterCredentialChange()
        } catch {
            self.error = UserFacingErrors.message(error)
            AppLog.error(.auth, "API key save failed for \(provider.provider.id): \(error.localizedDescription)")
        }
    }

    /// 이전 조회를 무효화하고 새 키로 다시 조회 — 실패하면 문제 카드로 드러남.
    private func refreshAfterCredentialChange() {
        let id = provider.provider.id
        let generation = dataStore.credentialsDidChange(for: id)
        Task { await dataStore.refreshAfterCredentialChange(providerID: id, credentialGeneration: generation) }
    }
}

extension View {
    /// 계정 상세 카드 안 작업 행의 공통 여백.
    func accountActionRowPadding() -> some View {
        padding(.horizontal, 12)
            .padding(.vertical, PanelMetrics.controlRowPadding)
            .frame(minHeight: 22)
    }
}
