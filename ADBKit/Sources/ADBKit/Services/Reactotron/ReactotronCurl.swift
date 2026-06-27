import Foundation

/// Builds a copy-pasteable `curl` command that reproduces a Reactotron-captured
/// API request. Lives in ADBKit (not the view) so it stays pure, `Sendable`,
/// and unit-testable without the UI.
public enum ReactotronCurl {
    /// Render `method`/`url`/`request` as a multi-line `curl` invocation.
    ///
    /// - Parameters:
    ///   - method: the HTTP verb as captured (any case).
    ///   - url: the request URL.
    ///   - request: the Reactotron `request` payload, read for `headers` and `data`.
    public static func command(method: String, url: String, request: JSONValue?) -> String {
        let verb = method.uppercased()
        let body = requestBody(request)
        var parts: [String] = ["curl"]
        // `curl` switches to POST the moment a body is present, so the verb must
        // be stated explicitly whenever it isn't a plain body-less GET —
        // otherwise copying a GET that carries a body silently produces a POST.
        if verb != "GET" || body != nil {
            parts.append("-X \(verb)")
        }
        parts.append(shellQuote(url))
        if let headers = request?["headers"]?.objectValue {
            for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
                let rendered = value.stringValue ?? rawJSON(value)
                parts.append("-H \(shellQuote("\(key): \(rendered)"))")
            }
        }
        if let body {
            parts.append("--data \(shellQuote(body))")
        }
        return parts.joined(separator: " \\\n  ")
    }

    /// The body to send, or `nil` when the request carries nothing meaningful —
    /// JSON null, an empty string, or an empty `{}` / `[]`. Keeps a body-less GET
    /// body-less (and therefore a GET, not a POST inferred by `curl`).
    private static func requestBody(_ request: JSONValue?) -> String? {
        guard let data = request?["data"], !data.isNull else { return nil }
        let rendered = data.stringValue ?? rawJSON(data)
        switch rendered {
        case "", "{}", "[]", "null": return nil
        default: return rendered
        }
    }

    /// Raw (non-marker-repaired) JSON, since a curl body must stay valid JSON —
    /// unlike `JSONValue.jsonString`, which rewrites Reactotron's `~~~ … ~~~`
    /// display markers.
    private static func rawJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}
