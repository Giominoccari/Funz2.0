import JWTKit
import Vapor

struct JWTAuthMiddleware: AsyncMiddleware, Sendable {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let bearer = request.headers.bearerAuthorization else {
            throw Abort(.unauthorized, reason: "Missing authorization header.")
        }

        let payload: FunghiJWTPayload
        do {
            payload = try await request.application.jwtKeys.verify(bearer.token, as: FunghiJWTPayload.self)
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
