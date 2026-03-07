import JWTKit
import Vapor

struct JWTKeysKey: StorageKey {
    typealias Value = JWTKeyCollection
}

extension Application {
    var jwtKeys: JWTKeyCollection {
        get {
            guard let keys = storage[JWTKeysKey.self] else {
                fatalError("JWTKeyCollection not configured. Call app.jwtKeys = ... in configure().")
            }
            return keys
        }
        set { storage[JWTKeysKey.self] = newValue }
    }
}
