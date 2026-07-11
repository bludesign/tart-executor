import FlyingFox
import Foundation

/// Helpers for serving the OpenAPI spec and a Redoc documentation page.
public enum APIDocs {
    /// Path the spec is served from; used as the Redoc `spec-url`.
    public static let specPath = "/api/v1/openapi.yaml"

    /// Response serving a raw OpenAPI YAML document.
    public static func yamlResponse(_ data: Data) -> HTTPResponse {
        HTTPResponse(statusCode: .ok, headers: [.contentType: "application/yaml"], body: data)
    }

    /// Response returned when the bundled spec resource is missing.
    public static func specNotFound() -> HTTPResponse {
        .jsonError("OpenAPI spec not found", statusCode: .notFound)
    }

    /// A self-contained Redoc documentation page pointed at the served spec. Redoc itself is
    /// loaded from a CDN by the operator's browser.
    public static func redocResponse(title: String, specPath: String = specPath) -> HTTPResponse {
        let html = """
        <!DOCTYPE html>
        <html>
          <head>
            <title>\(title)</title>
            <meta charset="utf-8"/>
            <meta name="viewport" content="width=device-width, initial-scale=1"/>
            <style>body { margin: 0; padding: 0; }</style>
          </head>
          <body>
            <redoc spec-url="\(specPath)"></redoc>
            <script src="https://cdn.redoc.ly/redoc/latest/bundles/redoc.standalone.js"></script>
          </body>
        </html>
        """
        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/html; charset=utf-8"],
            body: Data(html.utf8)
        )
    }
}
