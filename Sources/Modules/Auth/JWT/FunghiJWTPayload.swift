import Foundation
import JWTKit

struct FunghiJWTPayload: JWTPayload, Sendable {
    var sub: SubjectClaim
    var iss: IssuerClaim
    var iat: IssuedAtClaim
    var exp: ExpirationClaim
    var email: String

    func verify(using algorithm: some JWTAlgorithm) async throws {
        try exp.verifyNotExpired()
    }

    init(userID: String, email: String, expiresIn: TimeInterval = 900) {
        let now = Date()
        self.sub = SubjectClaim(value: userID)
        self.iss = IssuerClaim(value: "funghi-map")
        self.iat = IssuedAtClaim(value: now)
        self.exp = ExpirationClaim(value: now.addingTimeInterval(expiresIn))
        self.email = email
    }
}
