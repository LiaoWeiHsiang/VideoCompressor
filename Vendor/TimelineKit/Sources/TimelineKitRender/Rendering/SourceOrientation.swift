import AVFoundation
import CoreImage
import ImageIO

/// LOCAL PATCH (see VENDORED.md #9).
///
/// A video track's rotation lives in `preferredTransform`, not in its frames: phone
/// portrait footage is stored landscape and marked to be turned 90° on display. Only the
/// AVFoundation layer-instruction path applies that automatically. Anything that renders
/// decoded frames itself — the live preview through `VideoLayerComposer`, and the effects
/// path through `UnifiedCompositor` — receives the frames as stored, sideways.
///
/// The rotation cannot simply be multiplied into a `CIImage`: `preferredTransform` is
/// expressed in a top-left origin space while Core Image uses bottom-left, so applying the
/// matrix directly turns the picture the wrong way or mirrors it. Mapping to a
/// `CGImagePropertyOrientation` sidesteps that, because that type is defined in terms of
/// how the pixels should be *displayed*.
enum SourceOrientation {

    /// The display orientation a track's `preferredTransform` asks for.
    static func orientation(for transform: CGAffineTransform) -> CGImagePropertyOrientation {
        // Normalise away any scaling so only the rotation/flip is compared. Rotations
        // produced by `CGAffineTransform(rotationAngle:)` carry values like 6e-17 rather
        // than exact zeros, hence rounding.
        let columnScale = hypot(transform.a, transform.b)
        let rowScale    = hypot(transform.c, transform.d)
        guard columnScale > 0, rowScale > 0 else { return .up }

        let a = (transform.a / columnScale).rounded()
        let b = (transform.b / columnScale).rounded()
        let c = (transform.c / rowScale).rounded()
        let d = (transform.d / rowScale).rounded()

        switch (a, b, c, d) {
        case (0, 1, -1, 0):  return .right   // 90° clockwise on display
        case (-1, 0, 0, -1): return .down    // 180°
        case (0, -1, 1, 0):  return .left    // 90° counter-clockwise on display
        default:             return .up      // identity, or something we should not guess at
        }
    }

    /// Applies that orientation, leaving the result anchored at the origin.
    ///
    /// The fit maths downstream reads only `extent.width/height`, so an extent left with a
    /// non-zero origin would offset the picture inside the canvas.
    static func applied(_ orientation: CGImagePropertyOrientation, to image: CIImage) -> CIImage {
        guard orientation != .up else { return image }
        let rotated = image.oriented(orientation)
        guard rotated.extent.origin != .zero else { return rotated }
        return rotated.transformed(
            by: CGAffineTransform(translationX: -rotated.extent.origin.x,
                                  y: -rotated.extent.origin.y)
        )
    }
}
