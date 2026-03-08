import Testing
@testable import App

@Suite("GridGenerator Tests")
struct GridGeneratorTests {

    @Test("Generates points within bbox")
    func pointsWithinBbox() {
        let bbox = BoundingBox(minLat: 46.0, maxLat: 46.1, minLon: 11.0, maxLon: 11.1)
        let generator = GridGenerator(spacingMeters: 500)
        let points = generator.generate(bbox: bbox)

        #expect(!points.isEmpty)
        for point in points {
            #expect(point.latitude >= bbox.minLat)
            #expect(point.latitude <= bbox.maxLat + 0.01) // small tolerance for float
            #expect(point.longitude >= bbox.minLon)
            #expect(point.longitude <= bbox.maxLon + 0.01)
        }
    }

    @Test("Spacing between adjacent latitude points is approximately 500m")
    func latitudeSpacing() {
        let bbox = BoundingBox(minLat: 46.0, maxLat: 46.1, minLon: 11.0, maxLon: 11.0)
        let generator = GridGenerator(spacingMeters: 500)
        let points = generator.generate(bbox: bbox)

        guard points.count >= 2 else {
            Issue.record("Need at least 2 points")
            return
        }

        // Points along same longitude — check latitude spacing
        let sorted = points.sorted { $0.latitude < $1.latitude }
        let latDiff = sorted[1].latitude - sorted[0].latitude
        let distanceMeters = latDiff * .pi / 180.0 * 6_371_000

        // Should be approximately 500m (within 10% tolerance)
        #expect(distanceMeters > 450 && distanceMeters < 550)
    }

    @Test("Point count scales with area")
    func pointCountScalesWithArea() {
        let generator = GridGenerator(spacingMeters: 500)

        let smallBbox = BoundingBox(minLat: 46.0, maxLat: 46.05, minLon: 11.0, maxLon: 11.05)
        let largeBbox = BoundingBox(minLat: 46.0, maxLat: 46.1, minLon: 11.0, maxLon: 11.1)

        let smallCount = generator.generate(bbox: smallBbox).count
        let largeCount = generator.generate(bbox: largeBbox).count

        // 4x the area should give roughly 4x the points
        #expect(largeCount > smallCount * 3)
    }

    @Test("Trentino bbox generates expected order of magnitude")
    func trentinoGrid() {
        let generator = GridGenerator(spacingMeters: 500)
        let points = generator.generate(bbox: .trentino)

        // Trentino: ~0.7 lat x 1.0 lon degrees ≈ 78km x 70km ≈ 5460 km²
        // At 500m spacing: ~(156 * 140) ≈ ~21k points
        #expect(points.count > 10_000)
        #expect(points.count < 40_000)
    }

    @Test("Empty bbox generates minimal points")
    func emptyBbox() {
        let bbox = BoundingBox(minLat: 46.0, maxLat: 46.0, minLon: 11.0, maxLon: 11.0)
        let generator = GridGenerator(spacingMeters: 500)
        let points = generator.generate(bbox: bbox)
        #expect(points.count == 1)
    }

    @Test("Default GridPoint values")
    func defaultValues() {
        let bbox = BoundingBox(minLat: 46.0, maxLat: 46.0, minLon: 11.0, maxLon: 11.0)
        let generator = GridGenerator(spacingMeters: 500)
        let points = generator.generate(bbox: bbox)
        let point = points[0]
        #expect(point.altitude == 0)
        #expect(point.forestType == .none)
        #expect(point.soilType == .other)
    }
}
