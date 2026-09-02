import AppKit
import SwiftUI

enum RemoteMappingSide: Equatable {
    case left
    case right
}

struct RemoteMappingPlacement: Identifiable {
    let button: RemoteButton
    let side: RemoteMappingSide
    let anchor: UnitPoint
    let targetY: CGFloat

    var id: RemoteButton { button }
}

enum RemoteMappingLayout {
    static let canvasHeight: CGFloat = 570
    static let remoteSize = CGSize(width: 202, height: 410)
    static let arrowCardGap: CGFloat = 7
    /// Siri Remote 的原图带有很宽的透明边距；横向放大后，遥控器本体
    /// 与 RC003 在画布上的视觉尺寸一致，同时保留纵向按键比例。
    static let siriRemoteHorizontalScale: CGFloat = 2.1

    static let buttonPlacements: [RemoteMappingPlacement] = [
        RemoteMappingPlacement(button: .power, side: .left, anchor: UnitPoint(x: 0.386, y: 0.099), targetY: 0.08),
        RemoteMappingPlacement(button: .up, side: .left, anchor: UnitPoint(x: 0.502, y: 0.179), targetY: 0.23),
        RemoteMappingPlacement(button: .left, side: .left, anchor: UnitPoint(x: 0.362, y: 0.246), targetY: 0.38),
        RemoteMappingPlacement(button: .back, side: .left, anchor: UnitPoint(x: 0.406, y: 0.389), targetY: 0.53),
        RemoteMappingPlacement(button: .home, side: .left, anchor: UnitPoint(x: 0.406, y: 0.479), targetY: 0.68),
        RemoteMappingPlacement(button: .menu, side: .left, anchor: UnitPoint(x: 0.406, y: 0.569), targetY: 0.83),
        RemoteMappingPlacement(button: .right, side: .right, anchor: UnitPoint(x: 0.638, y: 0.246), targetY: 0.215),
        RemoteMappingPlacement(button: .ok, side: .right, anchor: UnitPoint(x: 0.502, y: 0.246), targetY: 0.36),
        RemoteMappingPlacement(button: .down, side: .right, anchor: UnitPoint(x: 0.502, y: 0.317), targetY: 0.505),
        RemoteMappingPlacement(button: .volumeUp, side: .right, anchor: UnitPoint(x: 0.604, y: 0.390), targetY: 0.65),
        RemoteMappingPlacement(button: .volumeDown, side: .right, anchor: UnitPoint(x: 0.604, y: 0.480), targetY: 0.795),
        RemoteMappingPlacement(button: .tv, side: .right, anchor: UnitPoint(x: 0.604, y: 0.569), targetY: 0.94),
    ]

    static let appleButtonPlacements: [RemoteMappingPlacement] = [
        // Siri Remote 图片是正方形素材，按遥控器实际按钮中心换算到画布坐标。
        // 左侧只有 6 张卡片，因此使用更宽的垂直间距；右侧还包含固定的语音卡片。
        RemoteMappingPlacement(button: .power, side: .left, anchor: UnitPoint(x: 0.63, y: 0.128), targetY: 0.09),
        RemoteMappingPlacement(button: .up, side: .left, anchor: UnitPoint(x: 0.50, y: 0.175), targetY: 0.252),
        RemoteMappingPlacement(button: .left, side: .left, anchor: UnitPoint(x: 0.32, y: 0.259), targetY: 0.414),
        RemoteMappingPlacement(button: .back, side: .left, anchor: UnitPoint(x: 0.41, y: 0.400), targetY: 0.576),
        RemoteMappingPlacement(button: .playPause, side: .left, anchor: UnitPoint(x: 0.41, y: 0.493), targetY: 0.738),
        RemoteMappingPlacement(button: .mute, side: .left, anchor: UnitPoint(x: 0.41, y: 0.584), targetY: 0.90),
        RemoteMappingPlacement(button: .right, side: .right, anchor: UnitPoint(x: 0.73, y: 0.259), targetY: 0.2125),
        RemoteMappingPlacement(button: .ok, side: .right, anchor: UnitPoint(x: 0.50, y: 0.259), targetY: 0.35),
        RemoteMappingPlacement(button: .down, side: .right, anchor: UnitPoint(x: 0.50, y: 0.347), targetY: 0.4875),
        RemoteMappingPlacement(button: .tv, side: .right, anchor: UnitPoint(x: 0.59, y: 0.400), targetY: 0.625),
        RemoteMappingPlacement(button: .volumeUp, side: .right, anchor: UnitPoint(x: 0.59, y: 0.493), targetY: 0.7625),
        RemoteMappingPlacement(button: .volumeDown, side: .right, anchor: UnitPoint(x: 0.59, y: 0.584), targetY: 0.90),
    ]

    static let voiceAnchor = UnitPoint(x: 0.630, y: 0.099)
    static let appleVoiceAnchor = UnitPoint(x: 0.50, y: 0.128)
    // 与右侧 6 张实体按键卡片共同铺满画布，避免底部留下大块空白。
    static let voiceTargetY: CGFloat = 0.075

    static func remotePoint(
        for anchor: UnitPoint,
        canvasWidth: CGFloat,
        horizontalScale: CGFloat = 1
    ) -> CGPoint {
        let remoteOrigin = CGPoint(
            x: canvasWidth / 2 - remoteSize.width / 2,
            y: (canvasHeight - remoteSize.height) / 2
        )
        let renderedX = 0.5 + (anchor.x - 0.5) * horizontalScale
        return CGPoint(
            x: remoteOrigin.x + remoteSize.width * renderedX,
            y: remoteOrigin.y + remoteSize.height * anchor.y
        )
    }

    static func cardEdgePoint(
        side: RemoteMappingSide,
        targetY: CGFloat,
        canvasWidth: CGFloat,
        cardWidth: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: side == .left ? cardWidth : canvasWidth - cardWidth,
            y: canvasHeight * targetY
        )
    }

    static func cardWidth(for canvasWidth: CGFloat) -> CGFloat {
        min(300, max(270, (canvasWidth - 260) / 2))
    }

    static func connectionControlPoints(
        start: CGPoint,
        end: CGPoint,
        side: RemoteMappingSide
    ) -> (start: CGPoint, end: CGPoint) {
        let direction: CGFloat = side == .left ? -1 : 1
        let distance = min(70, max(34, abs(end.x - start.x) * 0.58))
        let endpointDistance = min(42, max(24, distance * 0.6))
        return (
            CGPoint(x: start.x + direction * distance, y: start.y),
            CGPoint(x: end.x - direction * endpointDistance, y: end.y)
        )
    }

    static func arrowTip(cardEdge: CGPoint, side: RemoteMappingSide) -> CGPoint {
        let direction: CGFloat = side == .left ? -1 : 1
        return CGPoint(
            x: cardEdge.x - direction * arrowCardGap,
            y: cardEdge.y
        )
    }
}

struct RemoteMappingCanvas: View {
    @EnvironmentObject private var localization: LocalizationStore

    @Binding var selectedButton: RemoteButton
    let activeButtons: Set<RemoteButton>
    let supportedButtons: Set<RemoteButton>
    let usesSiriRemotePhoto: Bool
    let voiceActive: Bool
    let actionSummary: (RemoteButton, ButtonTrigger) -> String
    let onEdit: (RemoteButton, ButtonTrigger) -> Void

    private var visiblePlacements: [RemoteMappingPlacement] {
        (supportedButtons.contains(.playPause)
            ? RemoteMappingLayout.appleButtonPlacements
            : RemoteMappingLayout.buttonPlacements)
            .filter { supportedButtons.contains($0.button) }
    }

    var body: some View {
        GeometryReader { geometry in
            let metrics = Metrics(
                width: geometry.size.width,
                compact: supportedButtons.contains(.playPause)
            )
            ZStack {
                MappingRemotePhoto(usesSiriRemotePhoto: usesSiriRemotePhoto)
                    .frame(
                        width: RemoteMappingLayout.remoteSize.width,
                        height: RemoteMappingLayout.remoteSize.height
                    )
                    .position(x: metrics.remoteCenterX, y: RemoteMappingLayout.canvasHeight / 2)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                connectionLines(metrics: metrics)

                ForEach(visiblePlacements) { placement in
                    mappingCard(placement.button)
                        .frame(width: metrics.cardWidth, height: metrics.cardHeight)
                        .position(
                            x: metrics.cardCenterX(for: placement.side),
                            y: RemoteMappingLayout.canvasHeight * placement.targetY
                        )
                }

                voiceCard
                    .frame(width: metrics.cardWidth, height: metrics.cardHeight)
                    .position(
                        x: metrics.cardCenterX(for: .right),
                        y: RemoteMappingLayout.canvasHeight * RemoteMappingLayout.voiceTargetY
                    )
            }
        }
        .frame(height: RemoteMappingLayout.canvasHeight)
    }

    private func connectionLines(metrics: Metrics) -> some View {
        Canvas { context, _ in
            for placement in visiblePlacements {
                drawConnection(
                    context: &context,
                    start: metrics.remotePoint(
                        for: placement.anchor,
                        usesSiriRemotePhoto: usesSiriRemotePhoto
                    ),
                    end: metrics.cardEdgePoint(side: placement.side, targetY: placement.targetY),
                    side: placement.side,
                    selected: selectedButton == placement.button,
                    showsAnchor: activeButtons.contains(placement.button)
                )
            }
            drawConnection(
                context: &context,
                start: metrics.remotePoint(
                    for: usesSiriRemotePhoto
                        ? RemoteMappingLayout.appleVoiceAnchor
                        : RemoteMappingLayout.voiceAnchor,
                    usesSiriRemotePhoto: usesSiriRemotePhoto
                ),
                end: metrics.cardEdgePoint(side: .right, targetY: RemoteMappingLayout.voiceTargetY),
                side: .right,
                selected: voiceActive,
                showsAnchor: voiceActive
            )
        }
        .allowsHitTesting(false)
    }

    private func drawConnection(
        context: inout GraphicsContext,
        start: CGPoint,
        end: CGPoint,
        side: RemoteMappingSide,
        selected: Bool,
        showsAnchor: Bool
    ) {
        let arrowTip = RemoteMappingLayout.arrowTip(cardEdge: end, side: side)
        let controls = RemoteMappingLayout.connectionControlPoints(
            start: start,
            end: arrowTip,
            side: side
        )
        var path = Path()
        path.move(to: start)
        path.addCurve(to: arrowTip, control1: controls.start, control2: controls.end)

        let color = selected ? Color.accentColor : Color.secondary.opacity(0.42)
        context.stroke(
            path,
            with: .color(color),
            style: StrokeStyle(
                lineWidth: selected ? 1.6 : 1.0,
                lineCap: .round,
                lineJoin: .round
            )
        )
        if showsAnchor {
            context.fill(
                Path(ellipseIn: CGRect(x: start.x - 4, y: start.y - 4, width: 8, height: 8)),
                with: .color(Color.orange)
            )
        }

        let direction: CGFloat = side == .left ? -1 : 1
        var arrow = Path()
        arrow.move(to: arrowTip)
        arrow.addLine(to: CGPoint(x: arrowTip.x - direction * 6, y: arrowTip.y - 4))
        arrow.addLine(to: CGPoint(x: arrowTip.x - direction * 6, y: arrowTip.y + 4))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(color))
    }

    private func mappingCard(_ button: RemoteButton) -> some View {
        let selected = selectedButton == button
        let active = activeButtons.contains(button)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: symbol(for: button))
                    .frame(width: 14)
                Text(button.displayName(using: localization))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            HStack(spacing: 4) {
                ForEach(ButtonTrigger.allCases) { trigger in
                    Button {
                        selectedButton = button
                        onEdit(button, trigger)
                    } label: {
                        VStack(spacing: 1) {
                            Text(trigger.displayName(using: localization))
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(actionSummary(button, trigger))
                                .font(.system(size: 12, weight: trigger == .singleClick ? .semibold : .regular))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .help(
                        "\(button.displayName(using: localization)) · \(trigger.displayName(using: localization))"
                    )
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onTapGesture { selectedButton = button }
        .background(
            active
                ? Color.orange.opacity(0.12)
                : selected
                    ? Color.accentColor.opacity(0.10)
                    : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    active
                        ? Color.orange.opacity(0.65)
                        : selected
                            ? Color.accentColor.opacity(0.45)
                            : Color.secondary.opacity(0.15)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(button.displayName(using: localization)))
    }

    private var voiceCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                    .frame(width: 14)
                Text("button_mapping.voice_button.title")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                Text("button_mapping.voice_button.fixed")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(voiceActive ? Color.orange : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (voiceActive ? Color.orange : Color.secondary).opacity(0.12),
                        in: Capsule()
                    )
            }
            Text("button_mapping.voice_button.detail")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            voiceActive ? Color.orange.opacity(0.12) : Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(voiceActive ? Color.orange.opacity(0.65) : Color.secondary.opacity(0.15))
        }
        .accessibilityElement(children: .combine)
    }

    private func symbol(for button: RemoteButton) -> String {
        switch button {
        case .power: return "power"
        case .up: return "chevron.up"
        case .left: return "chevron.left"
        case .ok: return "circle.circle"
        case .right: return "chevron.right"
        case .down: return "chevron.down"
        case .back: return "arrow.uturn.backward"
        case .volumeUp: return "speaker.plus"
        case .home: return "house"
        case .volumeDown: return "speaker.minus"
        case .menu: return "line.3.horizontal"
        case .tv: return "tv"
        case .playPause: return "playpause"
        case .mute: return "speaker.slash"
        case .voice: return "mic.fill"
        }
    }

    private struct Metrics {
        let width: CGFloat
        let cardWidth: CGFloat
        let cardHeight: CGFloat

        init(width: CGFloat, compact: Bool) {
            self.width = width
            cardHeight = compact ? 64 : 72
            cardWidth = RemoteMappingLayout.cardWidth(for: width)
        }

        var remoteCenterX: CGFloat { width / 2 }

        func cardCenterX(for side: RemoteMappingSide) -> CGFloat {
            side == .left ? cardWidth / 2 : width - cardWidth / 2
        }

        func cardEdgePoint(side: RemoteMappingSide, targetY: CGFloat) -> CGPoint {
            RemoteMappingLayout.cardEdgePoint(
                side: side,
                targetY: targetY,
                canvasWidth: width,
                cardWidth: cardWidth
            )
        }

        func remotePoint(
            for anchor: UnitPoint,
            usesSiriRemotePhoto: Bool
        ) -> CGPoint {
            RemoteMappingLayout.remotePoint(
                for: anchor,
                canvasWidth: width,
                horizontalScale: usesSiriRemotePhoto
                    ? RemoteMappingLayout.siriRemoteHorizontalScale
                    : 1
            )
        }
    }
}

private enum MappingRemoteImageResource {
    static let xiaomiImage: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "RC003-remote-photo",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()

    static let siriImage: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "SiriRemote-photo",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()
}

private struct MappingRemotePhoto: View {
    let usesSiriRemotePhoto: Bool

    var body: some View {
        Group {
            if let photo = usesSiriRemotePhoto
                ? MappingRemoteImageResource.siriImage
                : MappingRemoteImageResource.xiaomiImage {
                Image(nsImage: photo)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(x: RemoteMappingLayout.siriRemoteHorizontalScale, y: 1)
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.quaternary)
                    .overlay {
                        Text("remote.photo.missing")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
            }
        }
    }
}
