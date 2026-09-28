import Foundation

/// Minimal Claude API client (Messages API over HTTPS; Swift has no official SDK).
/// Only ever called when you tap an AI button. Model, timeout and image size are in
/// config.json → ai.
enum ClaudeClient {
    struct Identification: Decodable {
        var name: String
        var confidence: Double
        var details: String
    }

    enum Failure: LocalizedError {
        case noAPIKey, offline, invalidKey, rateLimited(retryAfter: String?), overloaded,
             refused, badResponse(String), http(Int, String)

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "Add your Claude API key in Settings first."
            case .offline: return "No internet connection."
            case .invalidKey: return "The API key was rejected. Check it in Settings."
            case .rateLimited(let after):
                return "Too many requests. Try again" + (after.map { " in \($0) s." } ?? " in a moment.")
            case .overloaded: return "Claude is busy right now. Try again in a moment."
            case .refused: return "Claude declined to identify this."
            case .badResponse(let why): return "Unexpected answer (\(why))."
            case .http(let code, let message): return "Error \(code): \(message)"
            }
        }
    }

    /// Asks Claude to name the main object in a small JPEG.
    static func identifyObject(jpeg: Data, localGuess: String?) async throws -> Identification {
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else { throw Failure.noAPIKey }
        let config = AppConfig.shared.ai

        var prompt = "This is a crop from a phone camera. Name the main object in the centre in 1–4 everyday words " +
            "(e.g. \"AirPods case\", \"phone charger\", \"car keys\"). Give your confidence from 0 to 1 and one short detail " +
            "that helps photograph it (material, shape, or what it's next to)."
        if let guess = localGuess { prompt += " The on-device detector guessed \"\(guess)\" but wasn't sure." }

        // Structured output: Claude must answer with exactly this JSON shape.
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "confidence": ["type": "number"],
                "details": ["type": "string"]
            ],
            "required": ["name", "confidence", "details"],
            "additionalProperties": false
        ]
        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 1024,
            "output_config": [
                "effort": "low",
                "format": ["type": "json_schema", "schema": schema]
            ],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let result: (Data, URLResponse)
        do {
            result = try await URLSession.shared.data(for: request)
        } catch let error as URLError {
            let offlineCodes: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed]
            if offlineCodes.contains(error.code) { throw Failure.offline }
            throw error
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse("no HTTP response") }

        switch http.statusCode {
        case 200: break
        case 401, 403: throw Failure.invalidKey
        case 429: throw Failure.rateLimited(retryAfter: http.value(forHTTPHeaderField: "retry-after"))
        case 529, 500...599: throw Failure.overloaded
        default:
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "request failed"
            Log.error("Claude API \(http.statusCode): \(message)")
            throw Failure.http(http.statusCode, message)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.badResponse("not JSON")
        }
        if (json["stop_reason"] as? String) == "refusal" { throw Failure.refused }
        // The answer is the text block (there may be thinking blocks before it).
        let blocks = json["content"] as? [[String: Any]] ?? []
        guard let text = blocks.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String,
              let answer = try? JSONDecoder().decode(Identification.self, from: Data(text.utf8)) else {
            throw Failure.badResponse("no answer")
        }
        return answer
    }
}
