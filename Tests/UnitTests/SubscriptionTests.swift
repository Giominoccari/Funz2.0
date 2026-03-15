import Testing
import Foundation
import NIOCore
@testable import App

@Suite("Subscription Tests")
struct SubscriptionTests {

    // MARK: - PlanEntitlements

    @Test("Free entitlements have correct defaults")
    func freeEntitlements() {
        let free = PlanEntitlements.free
        #expect(free.maxZoom == 9)
        #expect(free.historyDays == 0)
        #expect(free.features.isEmpty)
    }

    @Test("PlanEntitlements is Codable round-trip")
    func entitlementsCodable() throws {
        let original = PlanEntitlements(maxZoom: 12, historyDays: 90, features: ["hd_tiles", "historical_data"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PlanEntitlements.self, from: data)
        #expect(decoded.maxZoom == 12)
        #expect(decoded.historyDays == 90)
        #expect(decoded.features == ["hd_tiles", "historical_data"])
    }

    // MARK: - Subscription Model

    @Test("Subscription isActive when status active and not expired")
    func isActiveTrue() {
        let sub = Subscription(
            userID: UUID(),
            plan: "pro",
            status: "active",
            currentPeriodEnd: Date().addingTimeInterval(86400)
        )
        #expect(sub.isActive == true)
    }

    @Test("Subscription not active when canceled")
    func isActiveCanceled() {
        let sub = Subscription(
            userID: UUID(),
            plan: "pro",
            status: "canceled",
            currentPeriodEnd: Date().addingTimeInterval(86400)
        )
        #expect(sub.isActive == false)
    }

    @Test("Subscription not active when expired")
    func isActiveExpired() {
        let sub = Subscription(
            userID: UUID(),
            plan: "pro",
            status: "active",
            currentPeriodEnd: Date().addingTimeInterval(-86400)
        )
        #expect(sub.isActive == false)
    }

    @Test("Subscription defaults to free plan")
    func defaultPlan() {
        let sub = Subscription(userID: UUID())
        #expect(sub.plan == "free")
        #expect(sub.status == "active")
    }

    // MARK: - SubscriptionConfig from app.yaml

    @Test("Config loads subscription plans from app.yaml")
    func configLoadsPlans() throws {
        let config = try ConfigLoader.load(from: "config/app.yaml")
        #expect(config.subscription.plans["free"] != nil)
        #expect(config.subscription.plans["pro"] != nil)
        #expect(config.subscription.plans["free"]?.maxZoom == 9)
        #expect(config.subscription.plans["pro"]?.maxZoom == 12)
        #expect(config.subscription.plans["pro"]?.historyDays == 90)
        #expect(config.subscription.plans["pro"]?.features.contains("hd_tiles") == true)
    }

    @Test("Config has checkout URLs")
    func configCheckoutURLs() throws {
        let config = try ConfigLoader.load(from: "config/app.yaml")
        #expect(!config.subscription.checkoutSuccessURL.isEmpty)
        #expect(!config.subscription.checkoutCancelURL.isEmpty)
    }

    @Test("Free plan has no features")
    func freePlanNoFeatures() throws {
        let config = try ConfigLoader.load(from: "config/app.yaml")
        let free = config.subscription.plans["free"]!
        #expect(free.features.isEmpty)
        #expect(free.historyDays == 0)
    }

    // MARK: - Stripe Webhook Signature

    @Test("Webhook signature verification succeeds with valid signature")
    func webhookSignatureValid() throws {
        let secret = "whsec_test_secret_key_12345"
        let payload = "{\"id\":\"evt_123\",\"type\":\"checkout.session.completed\"}"
        let timestamp = String(Int(Date().timeIntervalSince1970))

        // Compute valid signature
        let signedPayload = "\(timestamp).\(payload)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signedPayload.utf8), using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()

        let header = "t=\(timestamp),v1=\(hex)"

        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
        buffer.writeString(payload)

        #expect(throws: Never.self) {
            try StripeClient.verifyWebhookSignature(
                payload: buffer,
                signature: header,
                secret: secret
            )
        }
    }

    @Test("Webhook signature verification fails with wrong signature")
    func webhookSignatureInvalid() {
        let payload = "{\"id\":\"evt_123\"}"
        let timestamp = String(Int(Date().timeIntervalSince1970))
        let header = "t=\(timestamp),v1=invalid_signature_hex"

        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
        buffer.writeString(payload)

        #expect(throws: Error.self) {
            try StripeClient.verifyWebhookSignature(
                payload: buffer,
                signature: header,
                secret: "whsec_test"
            )
        }
    }

    @Test("Webhook signature verification fails with expired timestamp")
    func webhookSignatureExpired() {
        let secret = "whsec_test"
        let payload = "{\"id\":\"evt_123\"}"
        let oldTimestamp = String(Int(Date().timeIntervalSince1970) - 600)

        let signedPayload = "\(oldTimestamp).\(payload)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signedPayload.utf8), using: key)
        let hex = mac.map { String(format: "%02x", $0) }.joined()

        let header = "t=\(oldTimestamp),v1=\(hex)"

        var buffer = ByteBufferAllocator().buffer(capacity: payload.count)
        buffer.writeString(payload)

        #expect(throws: Error.self) {
            try StripeClient.verifyWebhookSignature(
                payload: buffer,
                signature: header,
                secret: secret
            )
        }
    }

    @Test("Webhook signature verification fails with missing v1")
    func webhookSignatureMissingV1() {
        let header = "t=12345"
        var buffer = ByteBufferAllocator().buffer(capacity: 2)
        buffer.writeString("{}")

        #expect(throws: Error.self) {
            try StripeClient.verifyWebhookSignature(
                payload: buffer,
                signature: header,
                secret: "whsec_test"
            )
        }
    }
}

// Re-export Crypto types used in tests
import Crypto
