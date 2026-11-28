import AppKit
import SwiftUI

/// 메뉴 막대 내용을 NSImage 템플릿으로 렌더링 — 검정·투명 픽셀을 macOS가 테마에 맞게 착색.
@MainActor
enum MenuBarStripRenderer {
    /// 마지막 결과 재사용 — 같은 입력에는 같은 이미지 인스턴스를 반환하여 불필요한 재그리기 방지.
    private static var lastRender: (content: MenuBarContent, style: MenuBarStyle, image: NSImage?)?

    /// 스트립 이미지 — 그릴 항목이 없으면 업데이트가 있을 때 점 붙은 앱 아이콘, 아니면 `nil`(호출자가 앱 아이콘 사용).
    static func image(for content: MenuBarContent, style: MenuBarStyle = .text) -> NSImage? {
        if let lastRender, lastRender.content.drawsSame(as: content), lastRender.style == style {
            AppLog.debug(.menubar, "strip cache hit")
            return lastRender.image
        }
        AppLog.debug(.menubar, "strip cache miss (rendering)")
        let image: NSImage?
        if content.isEmpty {
            image = content.updateAvailable ? appIconWithUpdateDot : nil
        } else {
            switch style {
            case .text: image = textImage(for: content)
            case .bars: image = barsImage(for: content)
            }
        }
        lastRender = (content, style, image)
        return image
    }

    /// 보이는 픽셀까지만 잘라내 메뉴 막대 항목 사이의 과도한 여백 방지.
    static func textImage(for content: MenuBarContent) -> NSImage? {
        guard !content.isEmpty else { return nil }
        let renderer = ImageRenderer(content: MenuBarTextStrip(content: content))
        renderer.scale = 2
        guard let rendered = renderer.cgImage else { return nil }
        let cgImage = trimmedToVisibleContent(rendered) ?? rendered
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width) / renderer.scale, height: CGFloat(cgImage.height) / renderer.scale)
        )
        image.isTemplate = true
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    /// 앱 아이콘 — 브랜드 마크를 읽지 못하면 시스템 기호 사용.
    static var appIcon: NSImage { MenuBarIcon.image ?? fallbackIcon }

    /// 최대 다섯 한도를 한 아이콘에 쌓고 넘친 개수·업데이트 표시 유지.
    static func barsImage(for content: MenuBarContent) -> NSImage? {
        let fractions = content.items.compactMap(\.fraction)
        guard !fractions.isEmpty else { return content.updateAvailable ? appIconWithUpdateDot : nil }
        let renderer = ImageRenderer(content: MenuBarBarsStrip(content: content, fractions: fractions))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = content.accessibilityText
        return image
    }

    /// 앱 아이콘 오른쪽 위에 업데이트 점 표시 — 점 둘레를 비워 마크와 분리.
    static let appIconWithUpdateDot: NSImage = {
        let icon = appIcon
        let image = NSImage(size: icon.size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            icon.draw(in: rect)
            let dot = CGRect(x: rect.maxX - 5, y: rect.maxY - 5, width: 5, height: 5)
            context.setBlendMode(.clear)
            context.fillEllipse(in: dot.insetBy(dx: -1, dy: -1))
            context.setBlendMode(.normal)
            context.setFillColor(.black)
            context.fillEllipse(in: dot)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L10n.dashboard("Update Available")
        return image
    }()

    /// 렌더된 strip의 완전 투명 여백 crop — 보이는 픽셀이 없으면 `nil`(호출자는 untrimmed 렌더 유지).
    nonisolated static func trimmedToVisibleContent(_ image: CGImage) -> CGImage? {
        guard let bounds = visibleBounds(of: image) else { return nil }
        return image.cropping(to: bounds)
    }

    /// non-zero alpha 픽셀의 bounding box(pixel 좌표, top-left 원점 — `CGImage.cropping(to:)`와 일치); 완전 투명이면 `nil`.
    nonisolated static func visibleBounds(of image: CGImage) -> CGRect? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &alpha, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where alpha[row + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// 브랜드 마크를 읽지 못했을 때의 시스템 아이콘.
    static let fallbackIcon: NSImage = {
        let image = NSImage(
            systemSymbolName: "gauge.with.dots.needle.bottom.50percent",
            accessibilityDescription: "egasu"
        ) ?? NSImage()
        image.isTemplate = true
        return image
    }()
}

/// 항목마다 프로바이더 마크(+ 계정 이니셜 배지) · 위 짧은 라벨 · 아래 값, 넘친 개수 캡슐, 업데이트 점.
struct MenuBarTextStrip: View {
    let content: MenuBarContent

    var body: some View {
        HStack(spacing: 11) {
            ForEach(content.items) { item in
                HStack(spacing: 4) {
                    glyph(item.icon)
                        .overlay(alignment: .bottomTrailing) {
                            if let badge = item.badge {
                                AccountBadge(text: badge)
                                    .offset(x: AccountBadge.overhang.width, y: AccountBadge.overhang.height)
                            }
                        }
                        .compositingGroup()
                        // 배치 경계 밖은 그려지지 않으므로 배지가 넘치는 만큼 오른쪽·위아래 공간 확보.
                        .padding(.trailing, item.badge == nil ? 0 : AccountBadge.overhang.width)
                        .padding(.vertical, item.badge == nil ? 0 : AccountBadge.overhang.height)
                    labelledValue(item)
                }
            }
            if content.overflow > 0 {
                overflowCount(content.overflow)
            }
            if content.updateAvailable {
                Image(nsImage: MenuBarStripRenderer.appIconWithUpdateDot)
                    .renderingMode(.template)
            }
        }
        .foregroundStyle(.black)
        .monospacedDigit()
        .padding(.horizontal, 2)
        .padding(.vertical, 1)
        .fixedSize()
        .compositingGroup()
    }

    private func labelledValue(_ item: MenuBarContent.Item) -> some View {
        let isBillingScope = ProviderAccountID.canonicalMetricID(item.id) == "openai-api.scope"
        return VStack(alignment: .leading, spacing: -2) {
            if !item.displayedLabel.isEmpty {
                Text(item.displayedLabel)
                    .font(.system(size: 9, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: item.accountLabel == nil ? nil : 96, alignment: .leading)
            }
            Text(item.displayedValue)
                .font(.system(size: 11, weight: .bold))
                .lineLimit(isBillingScope ? 1 : nil)
                .truncationMode(isBillingScope ? .middle : .tail)
                .frame(maxWidth: isBillingScope ? 96 : nil, alignment: .leading)
        }
        .fixedSize()
    }

    private func overflowCount(_ count: Int) -> some View {
        Text("+\(count)")
            .font(.system(size: 11, weight: .bold))
            .padding(.horizontal, 5)
            .frame(height: 16)
            .background(Capsule().fill(Color.black.opacity(0.16)))
    }

    private static let glyphSide: CGFloat = 16

    @ViewBuilder
    private func glyph(_ icon: IconSource) -> some View {
        if let mark = ProviderMarks.mark(for: icon.providerID) {
            ProviderIconShape(pathData: mark.path, inset: 0.04)
                .fill(Color.black)
                .frame(width: Self.glyphSide, height: Self.glyphSide)
        } else {
            Circle().fill(Color.black).frame(width: Self.glyphSide - 1, height: Self.glyphSide - 1)
        }
    }
}

/// 마크 오른쪽 아래 계정 이니셜 — 배지 둘레를 마크에서 오려 내 둘이 닿지 않음.
private struct AccountBadge: View {
    let text: String

    static let overhang = CGSize(width: 5, height: 2.5)

    var body: some View {
        ZStack {
            Capsule().fill(Color.black)
                .padding(-1.25)
                .blendMode(.destinationOut)
            Capsule().fill(Color.black)
            Text(text)
                .font(.system(size: 6.5, weight: .heavy))
                .padding(.horizontal, 2)
                .frame(minWidth: 8, minHeight: 8)
                .foregroundStyle(Color.black)
                .blendMode(.destinationOut)
        }
        .fixedSize()
    }
}

struct MenuBarBarsStrip: View {
    let content: MenuBarContent
    let fractions: [Double]

    var body: some View {
        HStack(spacing: 11) {
            MenuBarBars(fractions: fractions, side: 18)
            if content.overflow > 0 {
                Text("+\(content.overflow)")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 5)
                    .frame(height: 16)
                    .background(Capsule().fill(Color.black.opacity(0.16)))
            }
            if content.updateAvailable {
                Image(nsImage: MenuBarStripRenderer.appIconWithUpdateDot)
                    .renderingMode(.template)
            }
        }
        .foregroundStyle(.black)
        .monospacedDigit()
        .fixedSize()
    }
}

/// 작은 정사각형에 가로 막대 최대 다섯 개 표시.
/// 바탕 0.16 / 채움 1.0 / 잔여 0.24 불투명도, 거의 찬 막대도 100%와 구분되도록 꼬리 유지.
private struct MenuBarBars: View {
    let fractions: [Double]
    let side: CGFloat

    var body: some View {
        Canvas { context, size in
            draw(into: &context, size: size)
        }
        .frame(width: side, height: side)
    }

    private func draw(into context: inout GraphicsContext, size: CGSize) {
        let n = max(1, min(5, fractions.count))
        let pad = max(1, (size.width * 0.08).rounded())
        let gap = max(1, (size.width * 0.03).rounded())
        let trackX = pad
        let trackW = size.width - 2 * pad

        let layoutN = CGFloat(max(2, n))
        let trackH = max(1, ((size.height - 2 * pad - (layoutN - 1) * gap) / layoutN).rounded(.down))
        let rx = max(1, (trackH / 3).rounded(.down))

        let totalBarsHeight = CGFloat(n) * trackH + CGFloat(n - 1) * gap
        let yOffset = pad + ((size.height - 2 * pad - totalBarsHeight) / 2).rounded(.down)

        for i in 0..<n {
            let y = yOffset + CGFloat(i) * (trackH + gap) + 1

            context.fill(
                bar(x: trackX, y: y, w: trackW, h: trackH, leading: rx, trailing: rx),
                with: .color(.black.opacity(0.16))
            )

            let fill = MenuBarBarGeometry.fill(trackW: trackW, fraction: i < fractions.count ? fractions[i] : 0)
            if fill.fillW > 0 {
                let trailing = fill.fillW >= trackW ? rx : max(0, (rx * 0.35).rounded(.down))
                context.fill(
                    bar(x: trackX, y: y, w: fill.fillW, h: trackH, leading: rx, trailing: trailing),
                    with: .color(.black)
                )
            }
            if fill.fillW > 0, fill.remainderW > 0, let dividerX = fill.dividerX {
                context.fill(
                    bar(x: trackX + dividerX, y: y, w: fill.remainderW, h: trackH,
                        leading: max(0, (rx * 0.2).rounded(.down)), trailing: rx),
                    with: .color(.black.opacity(0.24))
                )
            }
        }
    }

    private func bar(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, leading: CGFloat, trailing: CGFloat) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: leading,
            bottomLeadingRadius: leading,
            bottomTrailingRadius: trailing,
            topTrailingRadius: trailing
        )
        .path(in: CGRect(x: x, y: y, width: w, height: h))
    }
}

/// Bars glyph의 순수 fill geometry — near-full 양자화와 최소 가시 remainder 규칙의 단위 테스트를 위해 분리.
enum MenuBarBarGeometry {
    struct Fill: Equatable {
        let fillW: CGFloat
        let remainderW: CGFloat
        let dividerX: CGFloat?
    }

    /// near-full(0.7–1.0) bar를 remainder 기준 15% 단위로 양자화 — 거의 가득 찬 bar가 100%로 읽히지 않도록 꼬리 유지.
    static func visualFraction(_ fraction: Double) -> Double {
        guard fraction.isFinite else { return 0 }
        let clamped = min(1, max(0, fraction))
        if clamped > 0.7, clamped < 1 {
            let remainder = 1 - clamped
            let quantized = min(1, (remainder / 0.15).rounded(.up) * 0.15)
            return max(0, 1 - quantized)
        }
        return clamped
    }

    static func fill(trackW: CGFloat, fraction: Double) -> Fill {
        guard fraction.isFinite, fraction > 0 else { return Fill(fillW: 0, remainderW: 0, dividerX: nil) }
        let visual = visualFraction(fraction)
        if visual >= 1 { return Fill(fillW: trackW, remainderW: 0, dividerX: nil) }
        let minVisible = max(4, (trackW * 0.2).rounded())
        let maxFillW = max(1, trackW - minVisible)
        let fillW = max(1, min(maxFillW, (trackW * CGFloat(visual)).rounded()))
        let trueRemainder = trackW - fillW
        let remainderW = min(trackW - 1, max(trueRemainder, minVisible))
        return Fill(fillW: fillW, remainderW: remainderW, dividerX: trackW - remainderW)
    }
}
