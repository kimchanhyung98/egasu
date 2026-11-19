import AppKit
import SwiftUI

/// 계정 추가 시트 — 프로바이더 선택 후 Claude·Codex 로그인, API 키 입력 또는 감지형 활성화.
/// 폭 300pt의 패널 부착 시트 — 텍스트 입력을 위해 앱 활성화 필요.
struct AddAccountSheet: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var chosenID: String?
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let chosenID, let runtime = container.addableProviders.first(where: { $0.provider.id == chosenID }) {
                step(for: runtime)
            } else {
                providerChoice
            }
        }
        .frame(width: 300)
        // 브라우저가 포커스를 가져가도 시트의 주 버튼은 활성 모양 유지.
        .environment(\.appearsActive, true)
        .onAppear {
            if NSApp.activationPolicy() != .prohibited { NSApp.activate(ignoringOtherApps: true) }
        }
    }

    // MARK: - Steps

    private var providerChoice: some View {
        let runtimes = container.addableProviders
        return VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: L10n.accounts("Add Account"), message: L10n.accounts("Choose a provider to add."))
            SheetChoiceList(
                items: runtimes.map(\.provider.id),
                selection: $selection,
                isEnabled: { !isAdded($0) },
                choose: { id in withAnimation(Motion.navigation) { chosenID = id } }
            ) { id in
                if let provider = runtimes.first(where: { $0.provider.id == id })?.provider {
                    ProviderIcon(source: provider.icon, inset: 0.06)
                        .frame(width: 20, height: 20)
                    Text(provider.displayName)
                    if isAdded(id) {
                        Spacer(minLength: 4)
                        Text(L10n.accounts("Added"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            SheetCancelRow { dismiss() }
        }
    }

    @ViewBuilder
    private func step(for runtime: ProviderRuntime) -> some View {
        let back = { withAnimation(Motion.navigation) { chosenID = nil } }
        let family = ProviderAccountID.family(of: runtime.provider.id)
        if ProviderAccountID.families.contains(family) {
            ManagedAccountSignInStep(family: family, icon: runtime.provider.icon, cancel: back) {
                container.setProviderEnabled(true, for: family)
                container.refreshAccountCatalog()
                dismiss()
            }
        } else if let keyProvider = runtime as? any APIKeyManaging {
            APIKeyAddStep(provider: keyProvider, cancel: back) { dismiss() }
        } else {
            TurnOnStep(runtime: runtime, cancel: back) { dismiss() }
        }
    }

    /// API 키 추가 가능 여부 — 새 키를 입력했거나, 이 Mac에 쓸 수 있는 키(환경 변수·저장 파일)가 이미 있음.
    static func canAddAPIKey(_ input: String, hasExistingKey: Bool) -> Bool {
        hasExistingKey || !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 이미 켠 단일 계정 프로바이더 — Claude·Codex는 계정을 여럿 둘 수 있어 항상 선택 가능.
    private func isAdded(_ id: String) -> Bool {
        !ProviderAccountID.families.contains(ProviderAccountID.family(of: id)) && container.enablement.isEnabled(id)
    }
}

/// API 키를 앱 설정 파일에 저장하여 환경 변수보다 우선 적용 — 프로바이더 활성화 후 즉시 조회.
/// 이 Mac에 쓸 수 있는 키가 이미 있으면 입력 없이 켜기만 가능.
private struct APIKeyAddStep: View {
    let provider: any APIKeyManaging
    let cancel: () -> Void
    let onAdded: () -> Void

    @Environment(AppContainer.self) private var container
    @Environment(WidgetDataStore.self) private var dataStore
    @State private var apiKey = ""
    @State private var error: String?
    @State private var hasExistingKey = false

    private var trimmedKey: String { apiKey.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: provider.provider.icon,
                title: L10n.accounts("Add %@", provider.provider.displayName),
                message: L10n.accounts(
                    "Enter an API key from your %@ account. egasu saves it on this Mac.", provider.provider.displayName),
                link: keyPage.map { (L10n.accounts("Get Your API Key"), $0) }
            )
            Form {
                Section {
                    SecureField(
                        L10n.customize("API Key"), text: $apiKey,
                        prompt: Text(L10n.accounts(hasExistingKey ? "Optional" : "Required"))
                    )
                    .onSubmit(add)
                } footer: {
                    if let error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Theme.notice)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: error == nil ? 76 : 100)
            SheetButtons(
                secondary: SheetAction(title: L10n.accounts("Cancel"), shortcut: .cancelAction, action: cancel),
                primary: SheetAction(
                    title: L10n.accounts("Add Account"),
                    isDisabled: !AddAccountSheet.canAddAPIKey(apiKey, hasExistingKey: hasExistingKey),
                    action: add
                )
            )
            .padding(.bottom, hasExistingKey ? 0 : 20)
            // 줄바꿈되는 안내는 높이를 고정한 Form 밖에 둠.
            if hasExistingKey {
                SheetStatus(text: L10n.accounts("Leave this empty to use the key already on this Mac."))
                    .padding(.bottom, 20)
            }
        }
        .onAppear {
            let status = provider.apiKeyStatus
            hasExistingKey = status != .notSet && status != .unreadable
        }
    }

    /// 프로바이더 링크에 API 키 관리 페이지가 있으면 키 발급 링크 제공.
    private var keyPage: URL? {
        provider.provider.links.first { $0.label.localizedCaseInsensitiveContains("key") }.flatMap {
            URL(string: $0.url)
        }
    }

    private func add() {
        guard AddAccountSheet.canAddAPIKey(apiKey, hasExistingKey: hasExistingKey) else { return }
        guard !trimmedKey.isEmpty else {
            // 이미 있는 키(환경 변수·저장 파일) 사용 — 켜면 바로 조회.
            container.setProviderEnabled(true, for: provider.provider.id)
            onAdded()
            return
        }
        do {
            try provider.saveAPIKey(trimmedKey)
        } catch {
            self.error = UserFacingErrors.message(error)
            return
        }
        let id = provider.provider.id
        container.setProviderEnabled(true, for: id)
        let generation = dataStore.credentialsDidChange(for: id)
        Task { await dataStore.refreshAfterCredentialChange(providerID: id, credentialGeneration: generation) }
        onAdded()
    }
}

/// 로컬 로그인 탐지 결과를 보여 주는 프로바이더 활성화 화면 — 미탐지 상태도 활성화 가능하며 이후 계정 경고로 안내.
private struct TurnOnStep: View {
    let runtime: ProviderRuntime
    let cancel: () -> Void
    let onTurnedOn: () -> Void

    @Environment(AppContainer.self) private var container
    @State private var isDetected: Bool?

    var body: some View {
        let name = runtime.provider.displayName
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: runtime.provider.icon,
                title: L10n.accounts("Add %@", name),
                message: L10n.accounts("egasu reads the %@ sign-in already on this Mac.", name)
            )
            SheetButtons(
                secondary: SheetAction(title: L10n.accounts("Cancel"), shortcut: .cancelAction, action: cancel),
                primary: SheetAction(title: L10n.accounts("Turn On")) {
                    container.setProviderEnabled(true, for: runtime.provider.id)
                    onTurnedOn()
                }
            )
            detection
                .padding(.bottom, 20)
        }
        .task { isDetected = await runtime.hasLocalCredentials() }
    }

    @ViewBuilder
    private var detection: some View {
        switch isDetected {
        case nil:
            SheetStatus(text: L10n.accounts("Looking for a sign-in…"), isWorking: true)
        case true?:
            SheetStatus(text: L10n.accounts("Found a sign-in on this Mac."))
        case false?:
            SheetStatus(
                text: L10n.accounts(
                    "No sign-in found. Sign in with %@ on this Mac first.", runtime.provider.displayName), isError: true
            )
        }
    }
}
