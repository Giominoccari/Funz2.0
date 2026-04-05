import JWTKit
import Vapor

struct JWTAuthMiddleware: AsyncMiddleware, Sendable {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Accept token from Authorization header or ?token= query param (used by WebView tile requests)
        let rawToken: String
        if let bearer = request.headers.bearerAuthorization {
            rawToken = bearer.token
        } else if let queryToken = request.query[String.self, at: "token"], !queryToken.isEmpty {
            rawToken = queryToken
        } else {
            throw Abort(.unauthorized, reason: "Missing authorization header.")
        }

        let payload: FunghiJWTPayload
        do {
            payload = try await request.application.jwtKeys.verify(rawToken, as: FunghiJWTPayload.self)
        } catch {
            throw Abort(.unauthorized, reason: "Invalid or expired token.")
        }

        request.storage[JWTPayloadKey.self] = payload
        return try await next.respond(to: request)
    }
}

// MARK: - Request storage

struct JWTPayloadKey: StorageKey {
    typealias Value = FunghiJWTPayload
}

extension Request {
    var jwtPayload: FunghiJWTPayload {
        get throws {
            guard let payload = storage[JWTPayloadKey.self] else {
                throw Abort(.unauthorized, reason: "JWT payload not found. Use JWTAuthMiddleware.")
            }
            return payload
        }
    }
}
