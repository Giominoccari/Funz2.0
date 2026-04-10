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
    // off-season scores (~0.05–0.20) render as faint haze,
    // while prime-season scores (0.5+) render as saturated orange-red.
    //
    // Visibility threshold: scores below this are fully transparent.
    // Set to 0.03 so that Italy is mostly covered with a faint heat fog.
    //
    // Alpha curve: power function score^0.4 gives steep rise in the off-season
    // range (0.03–0.40) so low-probability areas are visually differentiated
    // rather than all mapping to the same near-flat blue haze.
    // Range: ~39 (at 0.03) → ~137 (at 0.39) → ~200 (at 1.0)
    //
    // Color ramp: Cool blue-purple (low) → Warm amber-orange (high)
    // Designed to be visible over both satellite imagery and green terrain.
    static let visibilityThreshold: Double = 0.03

    static func color(for score: Double) -> RGBA {
        let clamped = min(1.0, max(0.0, score))

        guard clamped >= visibilityThreshold else {
            return .transparent
        }

        // Power-curve alpha: steeper rise at low scores than a linear ramp.
        // This gives clear contrast in the off-season 0.03–0.40 range where
        // a linear mapping would produce a nearly uniform flat appearance.
        let alpha = UInt8(pow(clamped, 0.4) * 200)  // ~39–200 range

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
