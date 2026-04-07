import Foundation

struct RGBA: Sendable, Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8

    static let transparent = RGBA(r: 0, g: 0, b: 0, a: 0)
}

enum Colormap {
    // Absolute score → color mapping. No dynamic stretching.
    //
    // Using absolute thresholds means the map correctly reflects the season:
    // off-season scores (~0.05–0.20) render as faint blue-purple or transparent,
    // while prime-season scores (0.5+) render as orange-red.
    //
    // Visibility threshold: scores below this are fully transparent.
    // Set to 0.12 so that marginal off-season areas don't clutter the map.
    //
    // Color ramp: Cool blue-purple (low) → Warm amber-orange (high)
    // Designed to be visible over both satellite imagery and green terrain.
    static let visibilityThreshold: Double = 0.12

    static func color(for score: Double) -> RGBA {
        let clamped = min(1.0, max(0.0, score))

        guard clamped >= visibilityThreshold else {
            return .transparent
        }

        // Alpha scales with score: low scores are subtle, high scores pop
        let alpha = UInt8(70 + clamped * 110)  // 70–180 range

        let r: Double
        let g: Double
        let b: Double

        if clamped < 0.33 {
            // Cool blue-purple (low probability)
            // #5B6BBF → #8B5CF6
            let t = clamped / 0.33
            r = 0.357 + t * (0.545 - 0.357)
            g = 0.420 + t * (0.361 - 0.420)
            b = 0.749 + t * (0.965 - 0.749)
        } else if clamped < 0.66 {
            // Purple → Warm orange (medium probability)
            // #8B5CF6 → #F59E0B
            let t = (clamped - 0.33) / 0.33
            r = 0.545 + t * (0.961 - 0.545)
            g = 0.361 + t * (0.620 - 0.361)
            b = 0.965 + t * (0.043 - 0.965)
        } else {
            // Warm orange → Hot red-orange (high probability)
            // #F59E0B → #EF4444
            let t = (clamped - 0.66) / 0.34
            r = 0.961 + t * (0.937 - 0.961)
            g = 0.620 + t * (0.267 - 0.620)
            b = 0.043 + t * (0.267 - 0.043)
        }

        return RGBA(
            r: UInt8(r * 255),
            g: UInt8(g * 255),
            b: UInt8(b * 255),
            a: alpha
        )
    }
}
