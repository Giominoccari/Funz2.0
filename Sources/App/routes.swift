import Vapor

func routes(_ app: Application) throws {
    app.get("health") { _ in
        ["status": "ok", "version": "0.1.0"]
    }

    // Serve index.html at root — no-cache forces WKWebView to revalidate on every launch
    // without re-downloading when the file hasn't changed (ETag-based)
    app.get { req async throws -> Response in
        let response = try await req.fileio.asyncStreamFile(at: req.application.directory.publicDirectory + "index.html")
        response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        return response
    }
}
