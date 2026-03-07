import Vapor

func routes(_ app: Application) throws {
    app.get("health") { _ in
        ["status": "ok", "version": "0.1.0"]
    }
}
