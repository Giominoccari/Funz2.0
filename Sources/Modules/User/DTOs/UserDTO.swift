import Vapor

enum UserDTO {
    struct ProfileResponse: Content {
        let id: UUID
        let email: String
        let displayName: String?
        let bio: String?
        let photoURL: String?
        let createdAt: Date?

        init(user: User) {
            self.id = user.id!
            self.email = user.email
            self.displayName = user.displayName
            self.bio = user.bio
            self.photoURL = user.photoURL
            self.createdAt = user.createdAt
        }
    }

    struct UpdateProfileRequest: Content {
        let displayName: String?
        let bio: String?
        let photoURL: String?
    }

    struct PhotoResponse: Content {
        let id: UUID
        let s3URL: String
        let species: String?
        let notes: String?
        let latitude: Double?
        let longitude: Double?
        let takenAt: Date?
        let createdAt: Date?

        init(photo: Photo) {
            self.id = photo.id!
            self.s3URL = photo.s3URL
            self.species = photo.species
            self.notes = photo.notes
            self.latitude = photo.latitude
            self.longitude = photo.longitude
            self.takenAt = photo.takenAt
            self.createdAt = photo.createdAt
        }
    }

    struct CreatePhotoRequest: Content {
        let species: String?
        let notes: String?
        let latitude: Double?
        let longitude: Double?
        let takenAt: Date?
    }
}
