import Foundation

struct RGBA: Sendable, Equatable {
    let r: UInt8
    let g: UInt8
    let b: UInt8
    let a: UInt8

    static let transparent = RGBA(r: 0, g: 0, b: 0, a: 0)
}

enum Colormap {
    // Green (low) → Yellow (mid) → Red (high)
    // Stops: 0.0=green, 0.5=yellow, 1.0=red
    //
    // `scoreRange` stretches the color ramp so that `minScore` maps to the
    // bottom of the gradient and `maxScore` maps to the top. This avoids
    // uniform-looking tiles when all scores cluster in a narrow band.
    static func color(for score: Double, scoreRange: (min: Double, max: Double)? = nil) -> RGBA {
        let clamped = min(1.0, max(0.0, score))

        if clamped < 0.001 {
            return .transparent
        }

        // Normalize score to 0-1 within the actual data range
        let s: Double
        if let range = scoreRange, range.max - range.min > 0.001 {
            s = min(1.0, max(0.0, (clamped - range.min) / (range.max - range.min)))
        } else {
            s = clamped
        }

        let r: Double
        let g: Double
        let b: Double

        if s < 0.5 {
            // Green → Yellow: R increases, G stays high
            let t = s / 0.5
            r = t
            g = 1.0
            b = 0.0
        } else {
            // Yellow → Red: G decreases, R stays high
            let t = (s - 0.5) / 0.5
            r = 1.0
            g = 1.0 - t
            b = 0.0
        }

        return RGBA(
            r: UInt8(r * 255),
            g: UInt8(g * 255),
            b: UInt8(b * 255),
            a: 200  // semi-transparent overlay for map
        )
    }
}
