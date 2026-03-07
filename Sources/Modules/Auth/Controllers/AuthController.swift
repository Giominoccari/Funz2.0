import Crypto
import Fluent
import Logging
import JWTKit
import Vapor

struct AuthController: RouteCollection, Sendable {
    private static let logger = Logger(label: "funghi.auth")
    private static let accessTokenLifetime: TimeInterval = 900 // 15 minutes
    private static let refreshTokenLifetime: TimeInterval = 30 * 24 * 3600 // 30 days

    func boot(routes: RoutesBuilder) throws {
        let auth = routes.grouped("auth")
        auth.post("register", use: register)
        auth.post("login", use: login)
        auth.post("refresh", use: refresh)
        auth.post("apple", use: appleLogin)
    }

    // MARK: - POST /auth/register

    @Sendable
    private func register(req: Request) async throws -> AuthDTO.TokenResponse {
        try AuthDTO.RegisterRequest.validate(content: req)
        let input = try req.content.decode(AuthDTO.RegisterRequest.self)

        let existingUser = try await User.query(on: req.db)
            .filter(\.$email == input.email.lowercased())
            .first()

        if existingUser != nil {
            throw Abort(.conflict, reason: "A user with this email already exists.")
        }

        let passwordHash = try Bcrypt.hash(input.password)
        let user = User(email: input.email.lowercased(), passwordHash: passwordHash)
        try await user.save(on: req.db)

        Self.logger.info("User registered", metadata: ["user_id": "\(user.id!)"])

        return try await generateTokens(for: user, on: req)
    }

    // MARK: - POST /auth/login

    @Sendable
    private func login(req: Request) async throws -> AuthDTO.TokenResponse {
        try AuthDTO.LoginRequest.validate(content: req)
        let input = try req.content.decode(AuthDTO.LoginRequest.self)

        guard let user = try await User.query(on: req.db)
            .filter(\.$email == input.email.lowercased())
            .first()
        else {
            throw Abort(.unauthorized, reason: "Invalid email or password.")
        }

        guard let storedHash = user.passwordHash,
              try Bcrypt.verify(input.password, created: storedHash)
        else {
            throw Abort(.unauthorized, reason: "Invalid email or password.")
        }

        Self.logger.info("User logged in", metadata: ["user_id": "\(user.id!)"])

        return try await generateTokens(for: user, on: req)
    }

    // MARK: - POST /auth/refresh

    @Sendable
    private func refresh(req: Request) async throws -> AuthDTO.TokenResponse {
        let input = try req.content.decode(AuthDTO.RefreshRequest.self)
        let tokenHash = SHA256.hash(input.refreshToken)

        guard let storedToken = try await RefreshToken.query(on: req.db)
            .filter(\.$tokenHash == tokenHash)
            .filter(\.$revokedAt == nil)
            .filter(\.$expiresAt > Date())
            .with(\.$user)
            .first()
        else {
            throw Abort(.unauthorized, reason: "Invalid or expired refresh token.")
        }

        // Revoke old token
        storedToken.revokedAt = Date()
        try await storedToken.save(on: req.db)

        Self.logger.info("Token refreshed", metadata: ["user_id": "\(storedToken.user.id!)"])

        return try await generateTokens(for: storedToken.user, on: req)
    }

    // MARK: - POST /auth/apple (stub)

    @Sendable
    private func appleLogin(req: Request) async throws -> AuthDTO.TokenResponse {
        // TODO: Implement Sign in with Apple verification
        throw Abort(.notImplemented, reason: "Sign in with Apple is not yet implemented.")
    }

    // MARK: - Helpers

    private func generateTokens(for user: User, on req: Request) async throws -> AuthDTO.TokenResponse {
        guard let userID = user.id else {
            throw Abort(.internalServerError, reason: "User has no ID.")
        }

        // Generate JWT access token
        let payload = FunghiJWTPayload(
            userID: userID.uuidString,
            email: user.email,
            expiresIn: Self.accessTokenLifetime
        )
        let accessToken = try await req.application.jwtKeys.sign(payload)

        // Generate opaque refresh token
        let rawToken = generateRandomToken()
        let tokenHash = SHA256.hash(rawToken)

        let refreshToken = RefreshToken(
            userID: userID,
            tokenHash: tokenHash,
            expiresAt: Date().addingTimeInterval(Self.refreshTokenLifetime)
        )
        try await refreshToken.save(on: req.db)

        return AuthDTO.TokenResponse(
            accessToken: accessToken,
            refreshToken: rawToken,
            expiresIn: Int(Self.accessTokenLifetime)
        )
    }

    private func generateRandomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - SHA256 helper

extension SHA256 {
    static func hash(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
