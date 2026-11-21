import SwiftUI

/// 화면 이동 중에도 실패한 작업의 안내를 유지 — 각 객체는 해당 탭을 처음 열 때 생성.
@MainActor
final class SettingsOperations {
    lazy var launchAtLogin = LaunchAtLoginSetting()
    lazy var commandLineTool = CommandLineToolInstaller()
    lazy var relauncher = AppRelauncher()
}

/// Settings의 그룹형 Form — 베타 업데이트를 켜면 Labs 탭 표시.
/// 탭을 바꾸거나 Settings에 들어오면 맨 위로.
struct SettingsScreen: View {
    @Environment(PopoverState.self) private var popover
    @Environment(UpdaterController.self) private var updater
    let operations: SettingsOperations
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// 그룹형 Form의 기본 카드 여백 — 패널 여백에 맞추도록 같은 크기 차감.
    private static let formRowInset: CGFloat = 20

    var body: some View {
        Form {
            switch popover.settingsTab {
            case .labs where updater.betaChannelEnabled:
                SettingsLabsTab(commandLineTool: operations.commandLineTool)
            case .general, .labs:
                SettingsGeneralTab(launchAtLogin: operations.launchAtLogin, relauncher: operations.relauncher)
            case .display: SettingsDisplayTab()
            case .alerts: SettingsAlertsTab()
            case .advanced: SettingsAdvancedTab()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .contentMargins(.horizontal, PanelMetrics.margin - Self.formRowInset, for: .scrollContent)
        .contentMargins(.top, DashboardContentView.barGap - Self.formRowInset, for: .scrollContent)
        .contentMargins(.bottom, PanelMetrics.margin - Self.formRowInset, for: .scrollContent)
        .scrollPosition($scrollPosition)
        .onChange(of: popover.settingsTab) { scrollPosition.scrollTo(edge: .top) }
        .onChange(of: popover.screen) { _, screen in
            if screen == .settings { scrollPosition.scrollTo(edge: .top) }
        }
    }
}

/// 행 제목 + ⓘ — 마우스를 올리면 설명.
struct SettingsTitle: View {
    let title: String
    let info: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .hoverTooltip(info)
                .accessibilityLabel(info)
        }
    }
}

/// 섹션 하단의 오류·주의 문구 — 일반 설명은 ⓘ에 표시.
struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.notice)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 메뉴형 선택 행.
struct SettingsPicker<Value: Hashable>: View {
    let label: String
    @Binding var selection: Value
    let options: [Value]
    let title: (Value) -> String

    init(_ label: String, selection: Binding<Value>, options: [Value], title: @escaping (Value) -> String) {
        self.label = label
        _selection = selection
        self.options = options
        self.title = title
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options, id: \.self) { Text(title($0)).tag($0) }
        }
    }
}
