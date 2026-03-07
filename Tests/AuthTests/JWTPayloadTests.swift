import Foundation
import Testing
import JWTKit
@testable import App

@Suite("JWT Payload Tests")
struct JWTPayloadTests {
    @Test("Payload with future expiration verifies successfully")
    func validPayload() async throws {
        let payload = FunghiJWTPayload(
            userID: "550e8400-e29b-41d4-a716-446655440000",
            email: "test@example.com",
            expiresIn: 900
        )

        // verify() only checks expiration, algorithm param is unused in our impl
        // Use a real key collection to test sign+verify round-trip
        let keys = await JWTKeyCollection().add(hmac: "test-secret", digestAlgorithm: .sha256)
        let token = try await keys.sign(payload)
        let verified = try await keys.verify(token, as: FunghiJWTPayload.self)

        #expect(verified.sub.value == "550e8400-e29b-41d4-a716-446655440000")
        #expect(verified.iss.value == "funghi-map")
        #expect(verified.email == "test@example.com")
    }

    @Test("Payload with past expiration fails verification")
    func expiredPayload() async throws {
        let payload = FunghiJWTPayload(
            userID: "550e8400-e29b-41d4-a716-446655440000",
            email: "test@example.com",
            expiresIn: -10
        )

        let keys = await JWTKeyCollection().add(hmac: "test-secret", digestAlgorithm: .sha256)
        let token = try await keys.sign(payload)

        await #expect(throws: (any Error).self) {
            try await keys.verify(token, as: FunghiJWTPayload.self)
        }
    }

    @Test("Payload issuer is funghi-map")
    func issuerClaim() {
        let payload = FunghiJWTPayload(
            userID: "some-id",
            email: "a@b.com"
        )
        #expect(payload.iss.value == "funghi-map")
    }

    @Test("Payload expiresIn defaults to 900 seconds")
    func defaultExpiration() {
        let before = Date()
        let payload = FunghiJWTPayload(
            userID: "some-id",
            email: "a@b.com"
        )
        let expectedExpiry = before.addingTimeInterval(900)

        // Allow 2 second tolerance
        #expect(abs(payload.exp.value.timeIntervalSince(expectedExpiry)) < 2)
    }
}
