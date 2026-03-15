# Funghi Map — API Reference

Base URL: `http://localhost:8080` (dev) — `https://api.funghimap.it` (prod)

All request/response bodies are JSON (`Content-Type: application/json`).

---

## Authentication

### JWT Overview

The API uses **RS256 JWT** access tokens for authentication. The flow is:

1. Register or login to receive an `accessToken` + `refreshToken`
2. Include the access token in every authenticated request as a Bearer token
3. When the access token expires (15 min), use the refresh token to get a new pair

#### Access Token (JWT)

| Field   | Description                          |
|---------|--------------------------------------|
| `sub`   | User UUID                            |
| `iss`   | `funghi-map`                         |
| `iat`   | Issued at (Unix timestamp)           |
| `exp`   | Expires at (issued + 900s = 15 min)  |
| `email` | User email                           |

#### Refresh Token

Opaque base64url string (32 random bytes). Valid for 30 days. **Rotated on every use** — after calling `/auth/refresh`, the old refresh token is revoked and a new one is issued.

#### Using the Access Token

Add the `Authorization` header to every authenticated request:

```
Authorization: Bearer <accessToken>
```

If the token is missing or expired, the API returns `401 Unauthorized`:

```json
{ "error": true, "reason": "Missing authorization header." }
```

```json
{ "error": true, "reason": "Invalid or expired token." }
```

---

## Endpoints

### Auth

#### `POST /auth/register`

Create a new account and receive tokens.

**Auth required**: No

**Request body:**

```json
{
  "email": "user@example.com",
  "password": "securepassword"
}
```

| Field      | Type   | Validation           |
|------------|--------|----------------------|
| `email`    | String | Valid email format    |
| `password` | String | Minimum 8 characters |

**Response** `200 OK`:

```json
{
  "accessToken": "eyJhbGciOiJSUzI1NiIs...",
  "refreshToken": "a1b2c3d4...",
  "expiresIn": 900
}
```

**Errors:**
- `409 Conflict` — email already registered
- `422 Unprocessable Entity` — validation failed

---

#### `POST /auth/login`

Authenticate with email and password.

**Auth required**: No

**Request body:**

```json
{
  "email": "user@example.com",
  "password": "securepassword"
}
```

**Response** `200 OK`: same as register.

**Errors:**
- `401 Unauthorized` — invalid email or password

---

#### `POST /auth/refresh`

Exchange a valid refresh token for a new access/refresh token pair. The old refresh token is revoked immediately.

**Auth required**: No

**Request body:**

```json
{
  "refreshToken": "a1b2c3d4..."
}
```

**Response** `200 OK`: same as register.

**Errors:**
- `401 Unauthorized` — invalid, expired, or already-revoked refresh token

---

#### `POST /auth/apple`

Sign in with Apple. **Not yet implemented** — returns `501`.

---

### User

All user endpoints require a valid JWT access token.

#### `GET /user/profile`

Get the authenticated user's profile.

**Auth required**: Yes

**Response** `200 OK`:

```json
{
  "id": "550e8400-e29b-41d4-a716-446655440000",
  "email": "user@example.com",
  "displayName": "Mario",
  "bio": "Fungaiolo dal 2010",
  "photoURL": "https://...",
  "createdAt": "2026-03-07T10:00:00Z"
}
```

---

#### `PUT /user/profile`

Update profile fields. All fields are optional — only provided fields are updated.

**Auth required**: Yes

**Request body:**

```json
{
  "displayName": "Mario Rossi",
  "bio": "Fungaiolo esperto",
  "photoURL": "https://..."
}
```

| Field         | Type    | Required |
|---------------|---------|----------|
| `displayName` | String? | No       |
| `bio`         | String? | No       |
| `photoURL`    | String? | No       |

**Response** `200 OK`: updated profile (same format as `GET /user/profile`).

---

#### `GET /user/photos`

List all photos uploaded by the authenticated user, newest first.

**Auth required**: Yes

**Response** `200 OK`:

```json
[
  {
    "id": "550e8400-e29b-41d4-a716-446655440000",
    "s3URL": "placeholder://pending-upload",
    "species": "Porcino",
    "notes": "Trovato sotto un faggio",
    "latitude": 46.07,
    "longitude": 11.12,
    "takenAt": "2026-03-07T08:30:00Z",
    "createdAt": "2026-03-07T10:00:00Z"
  }
]
```

---

#### `POST /user/photos`

Create a photo record. Currently saves with a placeholder S3 URL — actual file upload not yet implemented.

**Auth required**: Yes

**Request body:**

```json
{
  "species": "Porcino",
  "notes": "Trovato sotto un faggio",
  "latitude": 46.07,
  "longitude": 11.12,
  "takenAt": "2026-03-07T08:30:00Z"
}
```

All fields are optional.

**Response** `200 OK`: the created photo (same format as list item).

---

#### `DELETE /user/photos/:photoID`

Delete a photo owned by the authenticated user.

**Auth required**: Yes

**Response**: `204 No Content`

**Errors:**
- `400 Bad Request` — invalid UUID
- `404 Not Found` — photo not found or not owned by user

---

### Map

Map endpoints are currently **public** (no auth required). Subscription-based access control will be added in a future release.

#### `GET /map/tiles/:date/:z/:x/:y`

Fetch a single map tile (XYZ scheme). Returns a PNG image.

**Auth required**: No (MVP)

**Parameters:**

| Param  | Type   | Description                       |
|--------|--------|-----------------------------------|
| `date` | String | Date in `YYYY-MM-DD` format       |
| `z`    | Int    | Zoom level (6–12)                 |
| `x`    | Int    | Tile X coordinate                 |
| `y`    | Int    | Tile Y coordinate                 |

**Behavior:**
1. Checks local storage (`Storage/tiles/{date}/{z}/{x}/{y}.png`) first
2. Falls back to S3 presigned URL redirect (302) if AWS credentials are configured
3. Returns 404 if tile is not available in either location

**Response**: `200 OK` with `Content-Type: image/png`, or `302` redirect to S3.

**Errors:**
- `400 Bad Request` — invalid parameters or zoom outside 6–12
- `404 Not Found` — tile not available

---

#### `GET /map/dates`

List dates for which tiles are available locally.

**Auth required**: No

**Response** `200 OK`:

```json
["2026-03-14", "2026-03-13", "2026-03-12"]
```

Returns an empty array if no tiles are available.

---

### Health

#### `GET /health`

**Auth required**: No

**Response** `200 OK`:

```json
{
  "status": "ok",
  "version": "0.1.0"
}
```

---

## Error Format

All errors follow Vapor's standard format:

```json
{
  "error": true,
  "reason": "Description of what went wrong."
}
```

Common HTTP status codes:

| Code | Meaning                                      |
|------|----------------------------------------------|
| 400  | Bad request — invalid input or parameters    |
| 401  | Unauthorized — missing or invalid JWT        |
| 404  | Not found                                    |
| 409  | Conflict — resource already exists           |
| 422  | Validation error                             |
| 500  | Internal server error                        |
| 501  | Not implemented (e.g. Sign in with Apple)    |

---

## Client Integration Example

### Swift (URLSession)

```swift
// 1. Login
var loginReq = URLRequest(url: URL(string: "\(baseURL)/auth/login")!)
loginReq.httpMethod = "POST"
loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
loginReq.httpBody = try JSONEncoder().encode(["email": "user@example.com", "password": "pass1234"])

let (data, _) = try await URLSession.shared.data(for: loginReq)
let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)

// 2. Authenticated request
var profileReq = URLRequest(url: URL(string: "\(baseURL)/user/profile")!)
profileReq.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")

let (profileData, _) = try await URLSession.shared.data(for: profileReq)

// 3. Refresh when access token expires
var refreshReq = URLRequest(url: URL(string: "\(baseURL)/auth/refresh")!)
refreshReq.httpMethod = "POST"
refreshReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
refreshReq.httpBody = try JSONEncoder().encode(["refreshToken": tokens.refreshToken])

let (newData, _) = try await URLSession.shared.data(for: refreshReq)
let newTokens = try JSONDecoder().decode(TokenResponse.self, from: newData)
```

### cURL

```bash
# Register
curl -X POST http://localhost:8080/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"securepassword"}'

# Login
curl -X POST http://localhost:8080/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"user@example.com","password":"securepassword"}'

# Authenticated request
curl http://localhost:8080/user/profile \
  -H "Authorization: Bearer <accessToken>"

# Refresh tokens
curl -X POST http://localhost:8080/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"refreshToken":"<refreshToken>"}'
```
