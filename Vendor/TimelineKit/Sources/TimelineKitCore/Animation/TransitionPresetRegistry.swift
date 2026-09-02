import Foundation
import CoreImage
import CoreMedia

// MARK: - TransitionCategory

public enum TransitionCategory: String, CaseIterable, Sendable {
    case basic      = "基礎"
    case motion     = "移動"
    case zoom       = "縮放"
    case blur       = "模糊"
    case stylized   = "風格化"   // reserved — V7 P2+
}

// MARK: - TransitionPreset protocol

/// A transition preset defines the visual effect for blending two main-track frames.
///
/// Presets are stateless value types registered once at launch.
/// Overlay / text / subtitle layers must NEVER be passed to `render` —
/// they are composited by TimelineRenderer AFTER TransitionComposer returns.
public protocol TransitionPreset: Sendable {
    var presetID:    String             { get }
    var displayName: String             { get }
    var category:    TransitionCategory { get }
    /// SF Symbol name for the picker thumbnail icon.
    var iconName:    String             { get }

    /// Render the blended frame between outgoing and incoming at `progress` (0→1, already eased).
    ///
    /// Both `outgoing` and `incoming` are cropped to canvasSize.
    /// Returns a CIImage representing the composited main-visual result.
    func render(
        outgoing:   CIImage,
        incoming:   CIImage,
        progress:   Float,
        canvasSize: CGSize,
        context:    CIContext
    ) -> CIImage
}

// MARK: - TransitionPresetRegistry

/// Global registry mapping presetID → TransitionPreset.
///
/// Registration happens once at launch (TimelineRenderer.init calls
/// ensureDefaultsRegistered). Custom presets can be added via `register(_:)`.
public enum TransitionPresetRegistry {

    nonisolated(unsafe) private static var table: [String: any TransitionPreset] = [:]
    nonisolated(unsafe) private static var displayOrder: [String] = []
    nonisolated(unsafe) private static var defaultsLoaded = false

    // MARK: - Registration

    public static func register(_ preset: any TransitionPreset) {
        if table[preset.presetID] == nil {
            displayOrder.append(preset.presetID)
        }
        table[preset.presetID] = preset
    }

    public static func preset(for id: String) -> (any TransitionPreset)? {
        table[id]
    }

    public static var allIDs: [String] { displayOrder }

    public static var byCategory: [(category: TransitionCategory, ids: [String])] {
        TransitionCategory.allCases.compactMap { cat in
            let ids = displayOrder.filter { table[$0]?.category == cat }
            return ids.isEmpty ? nil : (cat, ids)
        }
    }

    // MARK: - Default preset bootstrap

    /// Called by TimelineRenderer.init — idempotent, safe to call multiple times.
    public static func ensureDefaultsRegistered() {
        guard !defaultsLoaded else { return }
        defaultsLoaded = true
        // 基礎
        register(CrossFadePreset())
        register(FadeThroughBlackPreset())
        register(FadeThroughWhitePreset())
        // 移動
        register(SlidePreset(presetID: "slideLeft",  displayName: "左移",    iconName: "arrow.left",         direction: .left))
        register(SlidePreset(presetID: "slideRight", displayName: "右移",    iconName: "arrow.right",        direction: .right))
        register(SlidePreset(presetID: "slideUp",    displayName: "上移",    iconName: "arrow.up",           direction: .up))
        register(SlidePreset(presetID: "slideDown",  displayName: "下移",    iconName: "arrow.down",         direction: .down))
        register(PushPreset (presetID: "pushLeft",   displayName: "推進·左", iconName: "arrow.left.to.line", direction: .left))
        register(PushPreset (presetID: "pushRight",  displayName: "推進·右", iconName: "arrow.right.to.line",direction: .right))
        register(PushPreset (presetID: "pushUp",     displayName: "推進·上", iconName: "arrow.up.to.line",   direction: .up))
        register(PushPreset (presetID: "pushDown",   displayName: "推進·下", iconName: "arrow.down.to.line", direction: .down))
        register(WipePreset (presetID: "wipeLeft",   displayName: "刷過·左", iconName: "rectangle.lefthalf.filled",  direction: .left))
        register(WipePreset (presetID: "wipeRight",  displayName: "刷過·右", iconName: "rectangle.righthalf.filled", direction: .right))
        register(SpinPreset())
        // 縮放
        register(ZoomInPreset())
        register(ZoomOutPreset())
        // 模糊
        register(BlurFadePreset())
        register(ZoomBlurPreset())
    }

    // MARK: - Compatibility mapping (legacy TransitionType → presetID)

    /// Maps a V2-era `EditorTransition.TransitionType` to a canonical presetID.
    /// Used when `EditorTransition.presetID` is nil (old drafts without the V7 field).
    public static func presetID(for type: EditorTransition.TransitionType) -> String {
        switch type {
        case .fade:             return "crossFade"
        case .dissolve:         return "crossFade"
        case .slideLeft:        return fallbackIfUnregistered("slideLeft")
        case .slideRight:       return fallbackIfUnregistered("slideRight")
        case .slideUp:          return fallbackIfUnregistered("slideUp")
        case .slideDown:        return fallbackIfUnregistered("slideDown")
        case .zoom:             return fallbackIfUnregistered("zoomIn")
        case .wipe:             return fallbackIfUnregistered("wipeLeft")
        case .crossFade:        return "crossFade"
        case .fadeThroughBlack: return fallbackIfUnregistered("fadeThroughBlack")
        case .pushLeft:         return fallbackIfUnregistered("pushLeft")
        case .pushRight:        return fallbackIfUnregistered("pushRight")
        case .zoomIn:           return fallbackIfUnregistered("zoomIn")
        case .blurFade:         return fallbackIfUnregistered("blurFade")
        }
    }

    private static func fallbackIfUnregistered(_ id: String) -> String {
        table[id] != nil ? id : "crossFade"
    }
}

// MARK: - CrossFadePreset

/// Standard dissolve: outgoing fades out while incoming fades in simultaneously.
struct CrossFadePreset: TransitionPreset {
    let presetID    = "crossFade"
    let displayName = "疊化"
    let category    = TransitionCategory.basic
    let iconName    = "circle.lefthalf.filled"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        outgoing.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: incoming,
            kCIInputTimeKey:        progress
        ])
    }
}

// MARK: - FadeThroughBlackPreset

/// Outgoing dissolves to black (first half), then black dissolves to incoming (second half).
struct FadeThroughBlackPreset: TransitionPreset {
    let presetID    = "fadeThroughBlack"
    let displayName = "閃黑"
    let category    = TransitionCategory.basic
    let iconName    = "moon.fill"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvasSize))
        if progress < 0.5 {
            let t = progress / 0.5
            return outgoing.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: black,
                kCIInputTimeKey:        t
            ])
        } else {
            let t = (progress - 0.5) / 0.5
            return black.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: incoming,
                kCIInputTimeKey:        t
            ])
        }
    }
}

// MARK: - SlidePreset

/// Incoming frame slides in from one side while outgoing slides off the other.
struct SlidePreset: TransitionPreset {
    let presetID:    String
    let displayName: String
    let category  = TransitionCategory.motion
    let iconName:    String

    /// LOCAL PATCH (VENDORED.md #20): up/down added, so the vertical motions that only
    /// existed as one-clip animations are available at a join too.
    enum Direction { case left, right, up, down }
    let direction: Direction

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let (ax, ay) = direction.axis
        let travel = ax != 0 ? canvasSize.width : canvasSize.height
        let offset = CGFloat(progress) * travel

        let outShift = CGAffineTransform(translationX: ax * offset, y: ay * offset)
        let inShift  = CGAffineTransform(translationX: ax * (offset - travel),
                                         y: ay * (offset - travel))

        let outSlid = outgoing.transformed(by: outShift).cropped(to: canvasRect)
        let inSlid  = incoming.transformed(by: inShift).cropped(to: canvasRect)
        return inSlid.composited(over: outSlid)
    }
}

extension SlidePreset.Direction {
    /// Unit vector the outgoing clip travels along. Core Image's y grows upward, so `.up`
    /// is +y — the opposite of what a UIKit-shaped guess would give.
    var axis: (CGFloat, CGFloat) {
        switch self {
        case .left:  return (-1, 0)
        case .right: return (1, 0)
        case .up:    return (0, 1)
        case .down:  return (0, -1)
        }
    }
}

// MARK: - PushPreset

/// Both frames move together in the same direction — outgoing exits, incoming enters seamlessly.
struct PushPreset: TransitionPreset {
    let presetID:    String
    let displayName: String
    let category  = TransitionCategory.motion
    let iconName:    String

    typealias Direction = SlidePreset.Direction
    let direction: Direction

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let (ax, ay) = direction.axis
        let travel = ax != 0 ? canvasSize.width : canvasSize.height
        let offset = CGFloat(progress) * travel

        let outPushed = outgoing
            .transformed(by: .init(translationX: ax * offset, y: ay * offset))
            .cropped(to: canvasRect)
        let inPushed = incoming
            .transformed(by: .init(translationX: ax * (offset - travel),
                                   y: ay * (offset - travel)))
            .cropped(to: canvasRect)

        return inPushed.composited(over: outPushed)
    }
}

// MARK: - ZoomInPreset

/// Outgoing frame zooms out (1.0→1.3 scale) while fading; incoming fades in at normal scale.
struct ZoomInPreset: TransitionPreset {
    let presetID    = "zoomIn"
    let displayName = "放大"
    let category    = TransitionCategory.zoom
    let iconName    = "plus.magnifyingglass"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let p          = CGFloat(progress)
        let center     = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        // Outgoing: zoom out from center (scale 1.0 → 1.3) and fade out
        let scale = 1.0 + p * 0.3
        let t = CGAffineTransform(translationX: center.x, y: center.y)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -center.x, y: -center.y)
        let outScaled = outgoing
            .transformed(by: t)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - p)
            ])
            .cropped(to: canvasRect)

        // Incoming: fade in at normal scale
        let inFaded = incoming
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
            ])
            .cropped(to: canvasRect)

        return inFaded.composited(over: outScaled)
    }
}

// MARK: - BlurFadePreset

/// Outgoing blurs out (radius 0→12) while fading; incoming fades in sharp.
struct BlurFadePreset: TransitionPreset {
    let presetID    = "blurFade"
    let displayName = "模糊疊化"
    let category    = TransitionCategory.blur
    let iconName    = "camera.filters"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let p          = CGFloat(progress)

        // Outgoing: gaussian blur radius 0→12 + fade out
        let blurRadius = p * 12.0
        let outBlurred = outgoing
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": blurRadius])
            .cropped(to: canvasRect)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - p)
            ])

        // Incoming: fade in sharp (no blur)
        let inFaded = incoming
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
            ])
            .cropped(to: canvasRect)

        return inFaded.composited(over: outBlurred)
    }
}

// MARK: - Presets carried over from the animation effects
//
// LOCAL PATCH (see VENDORED.md #20). 動畫 and 轉場 were two separate panels offering
// overlapping motions: 動畫 moved one clip on its own, 轉場 blended two. Keeping both meant
// the same idea ("zoom", "slide up") lived in two places and only one of them applied at a
// join. The motions below are the animation effects restated as joins, so the transition
// grid is the single place to choose an effect.

/// Mirror of `ZoomInPreset`: the outgoing clip falls away into the distance.
struct ZoomOutPreset: TransitionPreset {
    let presetID    = "zoomOut"
    let displayName = "縮小"
    let category    = TransitionCategory.zoom
    let iconName    = "minus.magnifyingglass"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let p = CGFloat(progress)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        let scale = 1.0 - p * 0.55
        let t = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
        let outScaled = outgoing
            .transformed(by: t)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1 - p)
            ])
            .cropped(to: canvasRect)

        let inFaded = incoming
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
            ])
            .cropped(to: canvasRect)

        return inFaded.composited(over: outScaled)
    }
}

/// 漸顯/漸隱 as a join: out to white, then in from white. Reads as a camera flash, and is
/// the counterpart to the existing fade through black.
struct FadeThroughWhitePreset: TransitionPreset {
    let presetID    = "fadeThroughWhite"
    let displayName = "閃白"
    let category    = TransitionCategory.basic
    let iconName    = "sun.max"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let white = CIImage(color: .white).cropped(to: canvasRect)
        let p = CGFloat(progress)
        let alpha = p < 0.5 ? p * 2 : (1 - p) * 2
        let veil = white.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
        ])
        let base = p < 0.5 ? outgoing : incoming
        return veil.composited(over: base).cropped(to: canvasRect)
    }
}

/// 景深推進 as a join: the outgoing clip rushes at the camera and defocuses.
struct ZoomBlurPreset: TransitionPreset {
    let presetID    = "zoomBlur"
    let displayName = "景深推進"
    let category    = TransitionCategory.blur
    let iconName    = "circle.hexagongrid"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let p = CGFloat(progress)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        let scale = 1.0 + p * 0.6
        let t = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -center.x, y: -center.y)
        let outPushed = outgoing
            .transformed(by: t)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": p * 20])
            .cropped(to: canvasRect)

        let inScale = 1.3 - p * 0.3
        let inT = CGAffineTransform(translationX: center.x, y: center.y)
            .scaledBy(x: inScale, y: inScale)
            .translatedBy(x: -center.x, y: -center.y)
        let inPulled = incoming
            .transformed(by: inT)
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": (1 - p) * 20])
            .cropped(to: canvasRect)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p)
            ])

        return inPulled.composited(over: outPushed)
    }
}

/// 環繞 as a join: the picture swings through a quarter turn as it changes.
struct SpinPreset: TransitionPreset {
    let presetID    = "spin"
    let displayName = "旋轉"
    let category    = TransitionCategory.motion
    let iconName    = "arrow.trianglehead.2.clockwise.rotate.90"

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let p = CGFloat(progress)
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        func spun(_ image: CIImage, angle: CGFloat, scale: CGFloat, alpha: CGFloat) -> CIImage {
            let t = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
                .scaledBy(x: scale, y: scale)
                .translatedBy(x: -center.x, y: -center.y)
            return image
                .transformed(by: t)
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
                ])
                .cropped(to: canvasRect)
        }

        // Scaled up while turning, so the corners never expose empty canvas.
        let quarter = CGFloat.pi / 2
        let outSpun = spun(outgoing, angle: quarter * p, scale: 1 + 0.45 * p, alpha: 1 - p)
        let inSpun = spun(incoming, angle: -quarter * (1 - p), scale: 1 + 0.45 * (1 - p), alpha: p)
        return inSpun.composited(over: outSpun)
    }
}

/// A hard edge sweeping across. The compositor already knew how to draw one; nothing in the
/// grid ever selected it.
struct WipePreset: TransitionPreset {
    let presetID:    String
    let displayName: String
    let category  = TransitionCategory.motion
    let iconName:    String
    let direction: SlidePreset.Direction

    func render(
        outgoing: CIImage, incoming: CIImage,
        progress: Float, canvasSize: CGSize, context: CIContext
    ) -> CIImage {
        let canvasRect = CGRect(origin: .zero, size: canvasSize)
        let (ax, ay) = direction.axis
        let travel = ax != 0 ? canvasSize.width : canvasSize.height
        let position = travel * CGFloat(progress)

        // The revealed strip advances from the edge the wipe travels away from.
        let revealed: CGRect
        if ax != 0 {
            revealed = ax < 0
                ? CGRect(x: canvasSize.width - position, y: 0, width: position, height: canvasSize.height)
                : CGRect(x: 0, y: 0, width: position, height: canvasSize.height)
        } else {
            revealed = ay < 0
                ? CGRect(x: 0, y: canvasSize.height - position, width: canvasSize.width, height: position)
                : CGRect(x: 0, y: 0, width: canvasSize.width, height: position)
        }

        guard revealed.width > 0, revealed.height > 0 else { return outgoing.cropped(to: canvasRect) }
        return incoming.cropped(to: revealed).composited(over: outgoing).cropped(to: canvasRect)
    }
}
