import Testing
import Fluent
import FluentPostgresDriver
import JWTKit
import VaporTesting
@testable import App

@Suite("Auth Controller Integration Tests", .serialized)
struct AuthControllerTests {
    private static let testRSAPrivateKey = """
-----BEGIN PRIVATE KEY-----
MIIEvwIBADANBgkqhkiG9w0BAQEFAASCBKkwggSlAgEAAoIBAQDa6q3hjnCJwOl7
4S9HzNM5YcR4tX+EpwPjgohQjLrdhHVgJwU7tacZffqYdL4JN8hUq8U8L7gAZlbU
DGPxiB0oNtn88X2rbtMLTZo34Zg9VbfamZR2QPoAuLI1aowvdnCbi4ZCGZkzHPWi
r9JOuvnkBrzZjBWeL4iZtQb5FtDy4MhKo9ljMlVI84dL4ZQEkxvLY92zqWokPeA/
/zHd37jRnnWv8zGyD4PNT2mZdPzFIDdkM00AsyggsX0fEnpMsaHW0tMuwvu8W6PE
9p2Amw7Kl/P3h8aG4/DAegozNIVYpmP/xOntn7ZtfYoHZsTClSSPAtbJmKhaxlcV
L4Tsgw1PAgMBAAECggEAadgWqxwp6EiX+vfE2uO66p8NFcm3NmVj+W+mxb9NKAY/
k/Y5zwVEngwtieHD8gQA/YMxcSinP7Y7W/oDpoeHhWaD3grKloUWT/w8yLDv4RPd
OTmRMN24onmqXC5ASkBrMKF0j+f9jNt/HiIBPmSjpq7lRw+2cg2Mb7i5ftybuRm1
gMGBPpotcg9UwuYeJRnPllPkNoJPwrYLct/SjsRyxQYd6/OTQfSehyM4JI/OM8Av
P0ZhhxRJzGYQz5xLS7ifMjWZ/1OkgiQG5uetxMZeHMCp5O6eFJr0SFeXdy6kSje+
WvLDP1j6MZBtEx3IqOMwV+zsHawcO4vkF9wcv/JXHQKBgQDuPNYCwvdcm+fLrPcI
moWrdnoRaE3uWGF/g/8pGFWb4uErJe7byUrm5CFoRdrdI+Bpc7QdF6/P7UgYfz3I
a9MtnOkrHVU8WV3w/WPIszu/H6wYSuj6GrLC1N7xQe5tCaeORxMiEPegA5L1DsgW
OmPLG0L+3Ed4j5/l+7lbOkVw/QKBgQDrPRIxKPVfh5rVDl1xHnCpTwxIlr9srhhE
bwtF3Y4Cyu78iM0Rhu41ZQj+CTzogWC+QAPLvsbZTdwhp6N0Ax39Nq/N2MXEaeX9
X/tm/7Zff27dSAGqwlDJMfbSUw8Wmdk3vX4Vre7cTuL2T/4zB1f6XyplHxx0cNpA
D5+g067/OwKBgQCHdBOCMnQONZ6PUWKLg7/og05YQ2O71ohoxhX3uZxDK7Y2oDS0
xjhOGvtbnAwam+FmU6Dewa72m8TYGNB5+cRyNLrmBqGF1JHzCT8Ix896lXl1vnHE
chWdbQbtST1UxZ586LBaOCdy1VVi++qLqNtAidmHqpsAUzjovDzhP7pnyQKBgQC+
0dlx+1Gf3nZgobh2zESDctX6BB7f4BFbYeB5GhHafheCzs3ai+OreHvk5kV8LYb2
jSMHIYhYOep5em0C7IxlHPlbN56lh2nDMRrUIFYl/U9HPOPtSpcRvfAECNBSexZT
OumOWHtMRsmhGJ6RckGRnaTcRnJkmi7QjFvmsBBihQKBgQDUyCo5AJaSSxjklKQJ
Sl60ilkMobqH1bv2ajnyaj2IjwYiCkldZcWkJ6n83z9PhGK0Fh2sTgxy04ep/Bm7
/wy6LPchIrgrsdyZyn1/vdTYM1tzTigdyo+6zmOX6ylcJO+wtwo3y79D4/mGVsPA
pNrnY0pTbRYvk5c0ZNNcPk6MYg==
-----END PRIVATE KEY-----
"""

    private func configureTestApp(_ app: Application) async throws {
        guard let databaseURL = Environment.get("DATABASE_URL") else {
            Issue.record("DATABASE_URL not set for tests")
            return
        }
        try app.databases.use(.postgres(url: databaseURL), as: .psql)

        let rsaKey = try Insecure.RSA.PrivateKey(pem: Self.testRSAPrivateKey)
        app.jwtKeys = await JWTKeyCollection().add(rsa: rsaKey, digestAlgorithm: .sha256)

        try AuthModule.configure(app)
        try UserModule.configure(app)
        try routes(app)
    }

    private func withTestApp(_ body: (Application) async throws -> Void) async throws {
        try await withApp(configure: configureTestApp) { app in
            try await app.autoMigrate()
            try await body(app)
            try await app.autoRevert()
        }
    }

    // MARK: - Register

    @Test("Register with valid credentials returns tokens")
    func registerSuccess() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthDTO.RegisterRequest(
                    email: "test@example.com",
                    password: "password123"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let tokens = try res.content.decode(AuthDTO.TokenResponse.self)
                #expect(!tokens.accessToken.isEmpty)
                #expect(!tokens.refreshToken.isEmpty)
                #expect(tokens.expiresIn == 900)
            })
        }
    }

    @Test("Register with duplicate email returns 409")
    func registerDuplicate() async throws {
        try await withTestApp { app in
            let tester = try app.testing()

            try await tester.test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthDTO.RegisterRequest(
                    email: "dup@example.com",
                    password: "password123"
                ))
            })

            try await tester.test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthDTO.RegisterRequest(
                    email: "dup@example.com",
                    password: "password456"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .conflict)
            })
        }
    }

    @Test("Register with invalid email returns 400")
    func registerInvalidEmail() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(["email": "not-an-email", "password": "password123"])
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    @Test("Register with short password returns 400")
    func registerShortPassword() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(["email": "test@example.com", "password": "short"])
            }, afterResponse: { res async throws in
                #expect(res.status == .badRequest)
            })
        }
    }

    // MARK: - Login

    @Test("Login with valid credentials returns tokens")
    func loginSuccess() async throws {
        try await withTestApp { app in
            let tester = try app.testing()

            try await tester.test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthDTO.RegisterRequest(
                    email: "login@example.com",
                    password: "password123"
                ))
            })

            try await tester.test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthDTO.LoginRequest(
                    email: "login@example.com",
                    password: "password123"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let tokens = try res.content.decode(AuthDTO.TokenResponse.self)
                #expect(!tokens.accessToken.isEmpty)
                #expect(!tokens.refreshToken.isEmpty)
            })
        }
    }

    @Test("Login with wrong password returns 401")
    func loginWrongPassword() async throws {
        try await withTestApp { app in
            let tester = try app.testing()

            try await tester.test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthDTO.RegisterRequest(
                    email: "wrong@example.com",
                    password: "password123"
                ))
            })

            try await tester.test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthDTO.LoginRequest(
                    email: "wrong@example.com",
                    password: "wrongpassword"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Login with non-existent email returns 401")
    func loginNotFound() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "auth/login", beforeRequest: { req in
                try req.content.encode(AuthDTO.LoginRequest(
                    email: "nobody@example.com",
                    password: "password123"
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - Refresh

    @Test("Refresh with valid token returns new tokens")
    func refreshSuccess() async throws {
        try await withTestApp { app in
            let tester = try app.testing()
            var refreshToken = ""

            try await tester.test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthDTO.RegisterRequest(
                    email: "refresh@example.com",
                    password: "password123"
                ))
            }, afterResponse: { res async throws in
                let tokens = try res.content.decode(AuthDTO.TokenResponse.self)
                refreshToken = tokens.refreshToken
            })

            try await tester.test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(AuthDTO.RefreshRequest(refreshToken: refreshToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let newTokens = try res.content.decode(AuthDTO.TokenResponse.self)
                #expect(!newTokens.accessToken.isEmpty)
                #expect(newTokens.refreshToken != refreshToken)
            })
        }
    }

    @Test("Refresh with already-used token returns 401")
    func refreshRevoked() async throws {
        try await withTestApp { app in
            let tester = try app.testing()
            var refreshToken = ""

            try await tester.test(.POST, "auth/register", beforeRequest: { req in
                try req.content.encode(AuthDTO.RegisterRequest(
                    email: "revoke@example.com",
                    password: "password123"
                ))
            }, afterResponse: { res async throws in
                let tokens = try res.content.decode(AuthDTO.TokenResponse.self)
                refreshToken = tokens.refreshToken
            })

            try await tester.test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(AuthDTO.RefreshRequest(refreshToken: refreshToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
            })

            try await tester.test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(AuthDTO.RefreshRequest(refreshToken: refreshToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    @Test("Refresh with invalid token returns 401")
    func refreshInvalid() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "auth/refresh", beforeRequest: { req in
                try req.content.encode(AuthDTO.RefreshRequest(refreshToken: "garbage-token"))
            }, afterResponse: { res async throws in
                #expect(res.status == .unauthorized)
            })
        }
    }

    // MARK: - Apple (stub)

    @Test("Apple login returns 501 not implemented")
    func appleNotImplemented() async throws {
        try await withTestApp { app in
            try await app.testing().test(.POST, "auth/apple", beforeRequest: { req in
                try req.content.encode(["identityToken": "fake"])
            }, afterResponse: { res async throws in
                #expect(res.status == .notImplemented)
            })
        }
    }
}
