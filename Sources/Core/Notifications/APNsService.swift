import AsyncHTTPClient
import Foundation
import JWTKit
import Logging
import NIOCore
import NIOFoundationCompat
import Vapor

/// Sends push notifications via Apple's HTTP/2 APNs API.
/// Authenticates using a JWT signed with the APNs auth key (.p8 file).
///
/// Required environment variables:
///   APNS_KEY_ID       — 10-char key ID from Apple Developer portal
///   APNS_TEAM_ID      — 10-char team ID
///   APNS_BUNDLE_ID    — app bundle identifier (e.g. "com.example.funz")
///   APNS_PRIVATE_KEY  — contents of the .p8 file (PEM string with newlines)
///   APNS_PRODUCTION   — "true" for production, anything else for sandbox
struct APNsService: Sendable {
    private let httpClient: HTTPClient
    private let keyID: String
    private let teamID: String
    private let bundleID: String
    private let privateKeyPEM: String
    private let isProduction: Bool
    private static let logger = Logger(label: "funghi.apns")

    // APNs JWT is valid for 1 hour; regenerate after 55 minutes.
    private static let tokenLifetimeSeconds: TimeInterval = 55 * 60

    init?(httpClient: HTTPClient) {
        guard
            let keyID    = Environment.get("APNS_KEY_ID"),
            let teamID   = Environment.get("APNS_TEAM_ID"),
            let bundleID = Environment.get("APNS_BUNDLE_ID"),
            let privKey  = Environment.get("APNS_PRIVATE_KEY")
        else {
            Self.logger.warning("APNs not configured — missing APNS_KEY_ID / APNS_TEAM_ID / APNS_BUNDLE_ID / APNS_PRIVATE_KEY")
            return nil
        }
        self.httpClient   = httpClient
        self.keyID        = keyID
        self.teamID       = teamID
        self.bundleID     = bundleID
        self.privateKeyPEM = privKey.replacingOccurrences(of: "\\n", with: "\n")
        self.isProduction = Environment.get("APNS_PRODUCTION") == "true"
    }

    /// Send a push notification to a single device token.
    /// - Parameters:
    ///   - deviceToken: Hex APNs device token string.
    ///   - title: Notification title.
    ///   - body: Notification body text.
    ///   - data: Custom key-value pairs attached to the notification payload.
    func send(
        to deviceToken: String,
        title: String,
        body: String,
        data: [String: String] = [:]
    ) async throws {
        let host = isProduction
            ? "https://api.push.apple.com"
            : "https://api.sandbox.push.apple.com"
        let url = "\(host)/3/device/\(deviceToken)"

        let jwt = try buildJWT()

        var payload: [String: Any] = [
            "aps": [
                "alert": ["title": title, "body": body],
                "sound": "default"
            ]
        ]
        for (k, v) in data { payload[k] = v }

        let bodyData = try JSONSerialization.data(withJSONObject: payload)

        var request = HTTPClientRequest(url: url)
        request.method = .POST
        request.headers.add(name: "authorization", value: "bearer \(jwt)")
        request.headers.add(name: "apns-topic", value: bundleID)
        request.headers.add(name: "apns-push-type", value: "alert")
        request.headers.add(name: "apns-priority", value: "10")
        request.headers.add(name: "content-type", value: "application/json")
        request.body = .bytes(ByteBuffer(data: bodyData))

        let response = try await httpClient.execute(request, timeout: .seconds(10))
        let status = response.status.code

        if status == 200 {
            Self.logger.debug("APNs push sent", metadata: ["token": "\(deviceToken.prefix(8))…"])
        } else {
            let bodyBuf = try? await response.body.collect(upTo: 1024)
            let errorText = bodyBuf.flatMap { String(buffer: $0) } ?? "no body"
            Self.logger.warning("APNs push failed", metadata: [
                "status": "\(status)",
                "body": "\(errorText)",
                "token": "\(deviceToken.prefix(8))…"
            ])
            throw APNsError.rejected(status: Int(status), reason: errorText)
        }
    }

    // MARK: - JWT

    private struct APNsPayload: JWTPayload {
        var iss: IssuerClaim
        var iat: IssuedAtClaim
        func verify(using _: some JWTAlgorithm) throws {}
    }

    private func buildJWT() throws -> String {
        let pemString = privateKeyPEM
        let key = try ES256PrivateKey(pem: pemString)
        var header = JWTHeader()
        header.kid = JWKIdentifier(string: keyID)

        let payload = APNsPayload(
            iss: IssuerClaim(value: teamID),
            iat: IssuedAtClaim(value: Date())
        )

        return try JWTKeyCollection()
            .add(ecdsa: key)
            .sign(payload, header: header)
    }

    // MARK: - Errors

    enum APNsError: Error {
        case rejected(status: Int, reason: String)
    }
}
