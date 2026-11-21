import AppKit

/// "About egasu" 메뉴용 표준 macOS 앱 정보 패널.
/// 메뉴 막대 앱은 먼저 활성화해야 패널이 다른 앱 뒤에 열리지 않음.
enum AboutPanel {
    @MainActor
    static func present() {
        NSApp.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// 가운데 정렬한 보조색 제작자 정보 — link 속성은 표준 패널에서 클릭 가능한 링크로 표시.
    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]

        let text = L10n.common("Fork maintained by %@\n\nOpen source on %@", "kimchanhyung98", "GitHub")
        let credits = NSMutableAttributedString(string: text, attributes: base)
        for (label, url) in [
            ("kimchanhyung98", "https://github.com/kimchanhyung98"),
            ("GitHub", "https://github.com/kimchanhyung98/egasu"),
        ] {
            credits.addAttribute(.link, value: url, range: (text as NSString).range(of: label))
        }
        return credits
    }
}
