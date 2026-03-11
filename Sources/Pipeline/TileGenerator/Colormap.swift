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
    static func color(for score: Double) -> RGBA {
        let s = min(1.0, max(0.0, score))

        if s < 0.001 {
            return .transparent
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
