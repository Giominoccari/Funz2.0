import Crypto
import Foundation
import Logging
import Vapor

/// Lightweight Stripe HTTP client using Vapor's `Client`.
/// No external SDK dependency — calls Stripe REST API directly.
struct StripeClient: Sendable {
    private static let logger = Logger(label: "funghi.stripe")
    private static let baseURL = "https://api.stripe.com/v1"

    private let secretKey: String

    init() throws {
        guard let key = Environment.get("STRIPE_SECRET_KEY") else {
            Self.logger.critical("STRIPE_SECRET_KEY environment variable is not set")
            throw Abort(.internalServerError, reason: "Stripe not configured.")
        }
        self.secretKey = key
    }

    // MARK: - Checkout Session

    func createCheckoutSession(
        customerEmail: String,
        priceID: String,
        successURL: String,
        cancelURL: String,
        client: any Vapor.Client
    ) async throws -> String {
        let response = try await client.post(URI(string: "\(Self.baseURL)/checkout/sessions")) { req in
            req.headers.basicAuthorization = .init(username: secretKey, password: "")
            req.headers.contentType = .urlEncodedForm
            try req.content.encode([
                "mode": "subscription",
                "customer_email": customerEmail,
                "line_items[0][price]": priceID,
                "line_items[0][quantity]": "1",
                "success_url": successURL,
                "cancel_url": cancelURL,
            ], as: .urlEncodedForm)
        }

        guard response.status == .ok else {
            Self.logger.error("Stripe checkout session failed", metadata: [
                "status": "\(response.status.code)",
            ])
            throw Abort(.badGateway, reason: "Failed to create Stripe checkout session.")
        }

        struct CheckoutSession: Decodable {
            let url: String
        }
        let session = try response.content.decode(CheckoutSession.self)
        return session.url
    }

    // MARK: - Webhook Signature Verification

    /// Verifies Stripe webhook signature (v1 scheme).
    /// See: https://stripe.com/docs/webhooks/signatures
    static func verifyWebhookSignature(
        payload: ByteBuffer,
        signature: String,
        secret: String,
        tolerance: TimeInterval = 300
    ) throws {
        let elements = signature.split(separator: ",").reduce(into: [String: String]()) { result, part in
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { result[String(kv[0])] = String(kv[1]) }
        }

        guard let timestampStr = elements["t"], let timestamp = TimeInterval(timestampStr) else {
            throw Abort(.badRequest, reason: "Missing timestamp in Stripe signature.")
        }

        guard let v1Sig = elements["v1"] else {
            throw Abort(.badRequest, reason: "Missing v1 signature.")
        }

        // Check tolerance
        let age = Date().timeIntervalSince1970 - timestamp
        guard abs(age) <= tolerance else {
            throw Abort(.badRequest, reason: "Webhook timestamp outside tolerance.")
        }

        // Compute expected signature: HMAC-SHA256(timestamp + "." + payload)
        let payloadString = String(buffer: payload)
        let signedPayload = "\(timestampStr).\(payloadString)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let expectedSig = HMAC<SHA256>.authenticationCode(
            for: Data(signedPayload.utf8),
            using: key
        )
        let expectedHex = expectedSig.map { String(format: "%02x", $0) }.joined()

        guard expectedHex == v1Sig else {
            throw Abort(.badRequest, reason: "Invalid webhook signature.")
        }
    }
}
