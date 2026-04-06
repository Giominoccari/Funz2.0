import Fluent
import Logging
import Vapor

struct UserController: RouteCollection, Sendable {
    private static let logger = Logger(label: "funghi.user")

    func boot(routes: RoutesBuilder) throws {
        let user = routes.grouped("user")
            .grouped(JWTAuthMiddleware())

        user.get("profile", use: getProfile)
        user.put("profile", use: updateProfile)
        user.post("device-token", use: registerDeviceToken)
        user.get("photos", use: listPhotos)
        user.post("photos", use: createPhoto)
        user.delete("photos", ":photoID", use: deletePhoto)
    }

    // MARK: - GET /user/profile

    @Sendable
    private func getProfile(req: Request) async throws -> UserDTO.ProfileResponse {
        let payload = try req.jwtPayload
        guard let userID = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized, reason: "Invalid user ID in token.")
        }

        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound, reason: "User not found.")
        }

        return UserDTO.ProfileResponse(user: user)
    }

    // MARK: - PUT /user/profile

    @Sendable
    private func updateProfile(req: Request) async throws -> UserDTO.ProfileResponse {
        let payload = try req.jwtPayload
        guard let userID = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized, reason: "Invalid user ID in token.")
        }

        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound, reason: "User not found.")
        }

        let input = try req.content.decode(UserDTO.UpdateProfileRequest.self)

        if let displayName = input.displayName {
            user.displayName = displayName
        }
        if let bio = input.bio {
            user.bio = bio
        }
        if let photoURL = input.photoURL {
            user.photoURL = photoURL
        }

        try await user.save(on: req.db)

        Self.logger.info("Profile updated", metadata: ["user_id": "\(userID)"])

        return UserDTO.ProfileResponse(user: user)
    }

    // MARK: - POST /user/device-token

    private struct DeviceTokenRequest: Content {
        let deviceToken: String
    }

    @Sendable
    private func registerDeviceToken(req: Request) async throws -> HTTPStatus {
        let payload = try req.jwtPayload
        guard let userID = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized)
        }
        let input = try req.content.decode(DeviceTokenRequest.self)
        guard let user = try await User.find(userID, on: req.db) else {
            throw Abort(.notFound)
        }
        user.deviceToken = input.deviceToken
        try await user.save(on: req.db)
        Self.logger.info("Device token registered", metadata: ["user_id": "\(userID)"])
        return .noContent
    }

    // MARK: - GET /user/photos

    @Sendable
    private func listPhotos(req: Request) async throws -> [UserDTO.PhotoResponse] {
        let payload = try req.jwtPayload
        guard let userID = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized, reason: "Invalid user ID in token.")
        }

        let photos = try await Photo.query(on: req.db)
            .filter(\.$user.$id == userID)
            .sort(\.$createdAt, .descending)
            .all()

        return photos.map { UserDTO.PhotoResponse(photo: $0) }
    }

    // MARK: - POST /user/photos (placeholder — no S3 upload yet)

    @Sendable
    private func createPhoto(req: Request) async throws -> UserDTO.PhotoResponse {
        let payload = try req.jwtPayload
        guard let userID = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized, reason: "Invalid user ID in token.")
        }

        let input = try req.content.decode(UserDTO.CreatePhotoRequest.self)

        let photo = Photo(
            userID: userID,
            s3URL: "placeholder://pending-upload",
            species: input.species,
            notes: input.notes,
            latitude: input.latitude,
            longitude: input.longitude,
            takenAt: input.takenAt
        )
        try await photo.save(on: req.db)

        Self.logger.info("Photo created (placeholder)", metadata: ["user_id": "\(userID)", "photo_id": "\(photo.id!)"])

        return UserDTO.PhotoResponse(photo: photo)
    }

    // MARK: - DELETE /user/photos/:photoID

    @Sendable
    private func deletePhoto(req: Request) async throws -> HTTPStatus {
        let payload = try req.jwtPayload
        guard let userID = UUID(uuidString: payload.sub.value) else {
            throw Abort(.unauthorized, reason: "Invalid user ID in token.")
        }

        guard let photoID = req.parameters.get("photoID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid photo ID.")
        }

        guard let photo = try await Photo.query(on: req.db)
            .filter(\.$id == photoID)
            .filter(\.$user.$id == userID)
            .first()
        else {
            throw Abort(.notFound, reason: "Photo not found.")
        }

        try await photo.delete(on: req.db)

        Self.logger.info("Photo deleted", metadata: ["user_id": "\(userID)", "photo_id": "\(photoID)"])

        return .noContent
    }
}
