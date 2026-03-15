import Testing
@testable import App

@Suite("PostGISAltitudeClient Tests")
struct PostGISAltitudeClientTests {

    @Test("PostGISAltitudeClient conforms to AltitudeClient protocol")
    func protocolConformance() {
        // Compile-time check: PostGISAltitudeClient must conform to AltitudeClient
        let _: any AltitudeClient.Type = PostGISAltitudeClient.self
    }
}
