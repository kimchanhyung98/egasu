import AppKit
import SwiftUI

/// ShareCardView를 PNG로 렌더링하여 클립보드에 복사.
/// ImageRenderer → CGImage → NSImage의 4배 렌더링 후 PNG 인코딩·클립보드 기록.
@MainActor
enum ShareCardRenderer {
    /// 화면 밖 렌더링 배율 — 4배로 360pt 카드를 1440px PNG로 생성.
    static let scale: CGFloat = 4

    /// 카드를 NSImage로 렌더링 — CGImage 생성 실패 시 nil, 포인트 크기는 원본·픽셀은 scale 배수.
    static func image<Card: View>(for view: Card) -> NSImage? {
        let renderer = ImageRenderer(content: view.environment(\.locale, L10n.locale))
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else { return nil }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        )
    }

    /// NSImage를 PNG로 인코딩 — 비트맵 생성 실패 시 nil.
    static func pngData(from image: NSImage) -> Data? {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// 기존 클립보드를 카드 PNG로 교체 — 인코딩·기록 실패 시 경고음과 로그.
    /// PNG 기록 성공 시에만 true 반환하여 복사 완료 표시의 근거 제공.
    @discardableResult
    static func copyToPasteboard(_ image: NSImage, pasteboard: NSPasteboard = .general) -> Bool {
        guard let png = pngData(from: image) else {
            AppDiagnostics.record(.shareScreenshot, result: .failure, category: .decoding,
                                  localContext: "Share card could not be encoded as PNG for the clipboard")
            NSSound.beep()
            return false
        }
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else {
            AppDiagnostics.record(.shareScreenshot, result: .failure, category: .other,
                                  localContext: "Share card pasteboard rejected the PNG")
            NSSound.beep()
            return false
        }
        AppDiagnostics.record(.shareScreenshot, result: .success)
        return true
    }

    /// 프로바이더 전체 또는 계정 하나의 카드를 PNG로 복사.
    /// 이메일 계정명은 생략. `blursAccountNames`가 켜지면 별명도 흐리게 표시.
    @discardableResult
    static func share(
        family: DashboardFamily,
        plans: [String: String],
        appearance: ColorScheme,
        blursAccountNames: Bool,
        layoutStyle: DashboardLayoutStyle = .minimal,
        pasteboard: NSPasteboard = .general
    ) -> Bool {
        renderAndCopy(ShareCardView(
            family: family, plans: plans, appearance: appearance,
            blursAccountNames: blursAccountNames, layoutStyle: layoutStyle
        ), pasteboard: pasteboard)
    }

    /// Priority 등 임의 공유 카드를 렌더링하여 복사.
    @discardableResult
    static func copy<Card: View>(_ card: Card) -> Bool {
        renderAndCopy(card)
    }

    /// 선택한 기간·지표의 Total Spend 카드를 렌더링하여 복사.
    /// 이미 집계된 total을 사용하여 화면과 같은 수치 표시 — 클립보드 기록 성공 여부 반환.
    @discardableResult
    static func shareTotalSpend(
        total: TotalSpend,
        metric: TotalSpendMetric,
        appearance: ColorScheme
    ) -> Bool {
        let projection = total.projection(for: metric)
        guard !projection.isEmpty else {
            NSSound.beep()
            return false
        }
        let view = TotalSpendShareCardView(total: total, metric: metric, appearance: appearance)
        return renderAndCopy(view)
    }

    /// 공유 동작의 공통 렌더링·복사 처리.
    /// 호출자가 반환값에 따라 복사 완료 표시.
    /// 실패 시 경고음과 단계별 로그 — 클립보드 기록 성공 여부 반환.
    @discardableResult
    private static func renderAndCopy<Card: View>(
        _ view: Card, pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let image = image(for: view) else {
            AppDiagnostics.record(.shareScreenshot, result: .failure, category: .other,
                                  localContext: "Share card ImageRenderer produced no image")
            NSSound.beep()
            return false
        }
        return copyToPasteboard(image, pasteboard: pasteboard)
    }
}
