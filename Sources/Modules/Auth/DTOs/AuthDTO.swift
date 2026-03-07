import Vapor

enum AuthDTO {
    struct RegisterRequest: Content, Validatable {
        let email: String
        let password: String

        static func validations(_ validations: inout Validations) {
            validations.add("email", as: String.self, is: .email)
            validations.add("password", as: String.self, is: .count(8...))
        }
    }

    struct LoginRequest: Content, Validatable {
        let email: String
        let password: String

        static func validations(_ validations: inout Validations) {
            validations.add("email", as: String.self, is: .email)
            validations.add("password", as: String.self, is: !.empty)
        }
    }

    struct RefreshRequest: Content {
        let refreshToken: String
    }

    struct TokenResponse: Content {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }
}
