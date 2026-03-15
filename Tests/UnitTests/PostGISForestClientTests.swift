import Testing
@testable import App

@Suite("PostGISForestClient Tests")
struct PostGISForestClientTests {

    // MARK: - CORINE → ForestType mapping

    @Test("CORINE code 311 maps to broadleaf")
    func corine311() {
        #expect(PostGISForestClient.mapCORINEToForestType(311) == .broadleaf)
    }

    @Test("CORINE code 312 maps to coniferous")
    func corine312() {
        #expect(PostGISForestClient.mapCORINEToForestType(312) == .coniferous)
    }

    @Test("CORINE code 313 maps to mixed")
    func corine313() {
        #expect(PostGISForestClient.mapCORINEToForestType(313) == .mixed)
    }

    @Test("CORINE non-forest codes map to none")
    func corineNonForest() {
        #expect(PostGISForestClient.mapCORINEToForestType(111) == .none)
        #expect(PostGISForestClient.mapCORINEToForestType(211) == .none)
        #expect(PostGISForestClient.mapCORINEToForestType(512) == .none)
        #expect(PostGISForestClient.mapCORINEToForestType(0) == .none)
    }

    // MARK: - ESDAC → SoilType mapping

    @Test("ESDAC code 1 maps to calcareous")
    func esdac1() {
        #expect(PostGISForestClient.mapESDACSoilType(1) == .calcareous)
    }

    @Test("ESDAC code 2 maps to siliceous")
    func esdac2() {
        #expect(PostGISForestClient.mapESDACSoilType(2) == .siliceous)
    }

    @Test("ESDAC code 3 maps to mixed")
    func esdac3() {
        #expect(PostGISForestClient.mapESDACSoilType(3) == .mixed)
    }

    @Test("ESDAC unknown codes map to other")
    func esdacUnknown() {
        #expect(PostGISForestClient.mapESDACSoilType(0) == .other)
        #expect(PostGISForestClient.mapESDACSoilType(99) == .other)
    }
}
