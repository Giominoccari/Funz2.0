import Logging
import Vapor

struct AdminKeyMiddleware: AsyncMiddleware {
    private static let logger = Logger(label: "funghi.admin")

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let expected = Environment.get("ADMIN_API_KEY"),
              let provided = request.headers.bearerAuthorization?.token,
              provided == expected
        else {
            Self.logger.warning("Unauthorized admin access attempt", metadata: [
                "ip": "\(request.remoteAddress?.description ?? "unknown")"
            ])
            throw Abort(.unauthorized, reason: "Invalid admin API key")
        }
        return try await next.respond(to: request)
    }
}
