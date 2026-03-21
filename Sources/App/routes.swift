import Vapor

func routes(_ app: Application) throws {
    app.get("health") { _ in
        ["status": "ok", "version": "0.1.0"]
    }

    // Serve index.html at root
    app.get { req async throws in
        try await req.fileio.asyncStreamFile(at: req.application.directory.publicDirectory + "index.html")
    }
}
