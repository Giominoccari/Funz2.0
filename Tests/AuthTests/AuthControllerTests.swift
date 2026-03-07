import Testing
import Fluent
import FluentPostgresDriver
import JWTKit
import VaporTesting
@testable import App

@Suite("Auth Controller Integration Tests")
struct AuthControllerTests {
    private static let testRSAPrivateKey = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEpAIBAAKCAQEA0Z3VS5JJcds3xfn/ygWyF8PbnGy0AHB7MhgHcTz6sE2I2yPB
    aNVFMBnPJGKMGCXGkMKIeL3W0FVO5IwnkEa4Tgpz3Hk2HMsqxMUsVGFJoG6QLKN
    M/cOwFhBOb3iGnGVMWbPvUBGfSPOtyTTPJRUqJk1WLjQC7G0Lq3JHNdWjfT7oRR1
    TbRCSCIJhDP3JHlAzMExYIAUkNymBD3dDQ3KiBn0kC95JBbBBn5jNGSLv3XmPBp7E
    9y0sBbD3a1Hzt/5kFmxMt0AuEnSsmFECnkLZ/LjDnGunL+FN9YE/jwGM8N3/eOVM
    S19wlHka+aMHgqHqLSS5DXMTJXK8ESJ0V+hZKwIDAQABAoIBAC5RgZ+hBx7xHNaM
    pPgwGMnCd6P5m0qlZF9bMCXKIGN0W5T+y5p4SnGCdJM5I0x4bR6M7RTJylGAy4sb
    BXN0WPMx3VLJZMzHN5KpcbOEm2YMXrFOlXb1m3HGBLF9sMV+TzZP0OQXQ3LBNpH
    91e4G4kP1b3XQ0UpDW4ThdR4+H5Ts9ZBbxH4C3bU6JhRfHlvL3u/O5jPiG1OVwuP
    F3iihPbE0k/2vCiKaBSB0tvRD3RjlVP6Z4Gii60P8SIQqv/XENNiLGnp0pjANxz4
    l3MBOhL8APvGETTR2K5a/r7+BKXkQHp3tIF7x0gzI9QSGbfbe+BpHQMfYK5rxY9p
    2FLNhcECgYEA6z4FT+o/AqrZLhMBlfrps+t2/C7G+B47B71R3FbmM++wTK3NjEBk
    d76b8PLFfwq/b6zQ1gOmRz0oYMJFJq5fMiskIIaeyBJsF0CnU7JQWP/TLnFmFLP5
    QIi+XWqTsGHUYJ/KBpVPIEiYfhABjuFli5mJMAKZ2bOZBmr2TH2v4DECgYEA4y0V
    gMb8TXQJnIdPO1oD3GIbMFNwPJjSQZ7Ctt8nFSQVoOcNbwGLxkNjlAYEBmpKL1hb
    TOiqXsMS41JoScC4hVJIcqPvOnhpA3YjSQqJO5Gi9VMEPDE75xei1fSf5ztakSD/k
    4RoaHEfKPFW0zIoZA8EfC2sGPNUZQ2EL4pKFRysCgYBiVhq1lBv6CEH3LqDUPPK7
    b0N9PhXmi+97DJrnNaO1K/Dv1KGOh/YBWktn8kFb3HVCAGGpLMRW6MBMEFJrfUlQ
    K1mcDqBZ+lNOTLKMqKKz7c2Cdd/G3UX+mOQ8VPzsMn0O+a2HZskFnfipTbedya3e
    wBevjyPJJawGr0k8cR3YsQKBgQDEq38FEMog0rJLZ3aKWAPceX3GKNL5pdfBP5Ih
    dVl8F/e3hLCMvHpHSJFD0i1gfOl1JB9UD1eDNGt2K+5gZG+nSKS5RSJEJDyCD+r0
    F30jAKSMICWaO2a4cPMm0EmzNAIFSbNTiGQVJ6KMwJCVq5I1TMl6DMGrC9JmVW9r
    G6fhvwKBgQCqxvVy6jhH1sDxjIbLqEH2eVP0RcHe1Gs+D1InWTZYHAJRFmVjuWtw
    Omd3mSHf7WPILFoB4YHdTXbQfDe0R+qwInz2KJDHcHKn4gT0Lqe6MNJw5bQBFjy8
    0iXXsFX3dq4VxhUJ3DBCnGpxjWIPyBpd/K+JeOMBRTx2LvfT7J+SGQ==
    -----END RSA PRIVATE KEY-----
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
        try await app.autoMigrate()
        try routes(app)
    }

    private func withTestApp(_ body: (Application) async throws -> Void) async throws {
        try await withApp(configure: configureTestApp) { app in
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
