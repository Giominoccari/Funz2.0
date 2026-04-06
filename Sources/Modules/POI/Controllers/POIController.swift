import Fluent
import Logging
import Vapor

struct POIController: RouteCollection, Sendable {
    private static let logger = Logger(label: "funghi.poi")

    func boot(routes: RoutesBuilder) throws {
        let poi = routes
            .grouped("user", "pois")
            .grouped(JWTAuthMiddleware(), SubscriptionMiddleware())

        poi.get(use: list)
        poi.post(use: create)
        poi.delete(":poiID", use: delete)
    }

    // MARK: - GET /user/pois

    @Sendable
    private func list(req: Request) async throws -> [POIDTO.POIResponse] {
        let userID = try userID(from: req)
        let pois = try await POI.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt, .ascending)
            .all()
        return pois.map { POIDTO.POIResponse(poi: $0) }
    }

    // MARK: - POST /user/pois

    @Sendable
    private func create(req: Request) async throws -> POIDTO.POIResponse {
        let userID = try userID(from: req)
        let input = try req.content.decode(POIDTO.CreateRequest.self)

        guard !input.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "POI name cannot be empty.")
        }
        guard (-90...90).contains(input.latitude), (-180...180).contains(input.longitude) else {
            throw Abort(.badRequest, reason: "Invalid coordinates.")
        }

        // Enforce quota from subscription entitlements
        let maxPOIs = req.planEntitlements.maxPOIs
        let existing = try await POI.query(on: req.db)
            .filter(\.$user.$id == userID)
            .count()
        guard existing < maxPOIs else {
            throw Abort(.forbidden, reason: "POI limit reached (\(maxPOIs)). Upgrade your plan for more.")
        }

        let poi = POI(userID: userID, name: input.name, latitude: input.latitude, longitude: input.longitude)
        try await poi.save(on: req.db)

        Self.logger.info("POI created", metadata: ["user_id": "\(userID)", "poi": "\(poi.name)"])
        return POIDTO.POIResponse(poi: poi)
    }

    // MARK: - DELETE /user/pois/:poiID

    @Sendable
    private func delete(req: Request) async throws -> HTTPStatus {
        let userID = try userID(from: req)
        guard let poiID = req.parameters.get("poiID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid POI ID.")
        }
        guard let poi = try await POI.query(on: req.db)
            .filter(\.$id == poiID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "POI not found.")
        }
        // Remove sent notification records first (cascade would handle it, but explicit is clearer)
        try await POINotification.query(on: req.db)
            .filter(\.$poi.$id == poiID)
            .delete()
        try await poi.delete(on: req.db)
        Self.logger.info("POI deleted", metadata: ["user_id": "\(userID)", "poi_id": "\(poiID)"])
        return .noContent
    }

    // MARK: - Helper

    private func userID(from req: Request) throws -> UUID {
        let payload = try req.jwtPayload
        guard let id = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized)
        }
        return id
    }
}
