// OpenVision - ChatGPTSubscription.swift
// Use a ChatGPT (Plus/Pro) subscription instead of an OpenAI API key.
//
// Signs in exactly like the Codex CLI (its public client id, loopback redirect on port 1455) and
// talks to the backend the CLI uses, chatgpt.com/backend-api/wham. That backend differs from the
// public API in ways verified against it:
// - Responses API only (no Chat Completions), `store: false`, top-level `instructions` required.
// - `stream: true` is mandatory ("Stream must be set to true").
// - The final `response.completed` event carries an EMPTY `output` — the items arrive one by one
//   as `response.output_item.done` events, so that's what we collect.
// - The model list is per-account and gated by Codex client version (an old version returns
//   only a couple of models), so it's fetched live rather than hardcoded.
//
// This is the Codex CLI's integration surface, not a documented third-party API: OpenAI can change
// it at any time. Everything provider-specific lives here so a change is a one-file edit.

import Foundation

enum ChatGPTSubscription {

    static let provider = OAuthProvider(
        id: "chatgpt",
        displayName: "ChatGPT",
        authorizeURL: URL(string: "https://auth.openai.com/oauth/authorize")!,
        tokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
        clientId: "app_EMoamEEZ73f0CkXaXp7hrann",
        scope: "openid profile email offline_access",
        // The Codex CLI client id is registered against exactly this redirect.
        redirectHost: "localhost",
        redirectPort: 1455,
        redirectPath: "/auth/callback",
        extraAuthParams: [
            "originator": "codex_cli_rs",
            "codex_cli_simplified_flow": "true",
            "id_token_add_organizations": "true",
        ],
        refreshSkew: 60
    )

    static let baseURL = "https://chatgpt.com/backend-api/wham"

    /// Codex CLI version reported to `/models`, which gates the list by client version.
    static let modelsClientVersion = "0.160.0"

    /// Fastest model on the subscription at the time of writing (~1.5s for a one-sentence answer)
    /// — latency matters most for a voice assistant. Users can pick any model from the live list.
    static let defaultModel = "gpt-6-luna"

    struct Model: Identifiable, Hashable {
        let slug: String
        let displayName: String
        var id: String { slug }
    }

    // MARK: - Models

    /// Image-capable models the account can use, in the server's order.
    static func fetchModels() async throws -> [Model] {
        let url = URL(string: "\(baseURL)/models?client_version=\(modelsClientVersion)")!
        let (data, _) = try await send { credentials in
            var request = URLRequest(url: url)
            authorize(&request, credentials)
            request.timeoutInterval = 20
            return request
        }
        return parseModels(data)
    }

    static func parseModels(_ data: Data) -> [Model] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { m in
            guard let slug = m["slug"] as? String,
                  (m["visibility"] as? String ?? "list") == "list",
                  (m["input_modalities"] as? [String])?.contains("image") ?? true else { return nil }
            return Model(slug: slug, displayName: m["display_name"] as? String ?? slug)
        }
    }

    // MARK: - Responses

    /// One Responses turn. Returns the output items (messages, function calls, reasoning) in order;
    /// callers append them to `input` verbatim when continuing a tool loop.
    static func respond(model: String, instructions: String, input: [[String: Any]],
                        tools: [[String: Any]]) async throws -> [[String: Any]] {
        var body: [String: Any] = [
            "model": model,
            "instructions": instructions,
            "input": input,
            "store": false,
            "stream": true,
            // With store:false, reasoning models need their reasoning items echoed back in a tool
            // loop; the encrypted content is what makes that possible.
            "include": ["reasoning.encrypted_content"],
            // Time to first token dominates a voice turn. (The Codex CLI sends a reasoning object
            // on every request, and /models lists "low" for every model.)
            "reasoning": ["effort": "low"],
        ]
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await send { credentials in
            var request = URLRequest(url: URL(string: "\(baseURL)/responses")!)
            request.httpMethod = "POST"
            authorize(&request, credentials)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = payload
            request.timeoutInterval = 90
            return request
        }
        let (items, failure) = parseStream(data)
        if let failure { throw ChatGPTSubscriptionError.api(failure) }
        return items
    }

    /// Roughly the API-key path's `max_tokens: 400` (~4 characters per token). This backend rejects
    /// `max_output_tokens` ("Unsupported parameter"), so the cap is applied to the reply instead.
    static let maxSpokenCharacters = 1600

    /// Cut a reply to `maxSpokenCharacters` at a sentence boundary, so a verbose answer isn't
    /// spoken in full. The first sentence is always kept, even if it alone is longer.
    static func capForSpeech(_ reply: String) -> String {
        guard reply.count > maxSpokenCharacters else { return reply }
        var kept = ""
        for sentence in TextChunking.sentences(reply) {
            let next = kept.isEmpty ? sentence : kept + " " + sentence
            if next.count > maxSpokenCharacters && !kept.isEmpty { break }
            kept = next
        }
        return kept
    }

    /// Output items + the first error message from a Responses SSE body.
    static func parseStream(_ data: Data) -> (items: [[String: Any]], error: String?) {
        var items: [[String: Any]] = []
        var failure: String?
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("data:") {
            let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let event = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "response.output_item.done":
                if let item = event["item"] as? [String: Any] { items.append(item) }
            case "response.failed", "response.incomplete", "error":
                let response = event["response"] as? [String: Any]
                let error = (response?["error"] ?? event["error"]) as? [String: Any]
                failure = failure ?? (error?["message"] as? String ?? event["message"] as? String
                    ?? (response?["incomplete_details"] as? [String: Any])?["reason"] as? String ?? "request failed")
            default:
                continue
            }
        }
        return (items, failure)
    }

    /// Chat Completions tool specs ({"type":"function","function":{…}}) → Responses format
    /// ({"type":"function","name":…}), so the existing tool registry is reused as-is.
    static func responsesTools(fromChatTools tools: [[String: Any]]) -> [[String: Any]] {
        tools.compactMap { tool in
            guard let function = tool["function"] as? [String: Any] else { return nil }
            var converted: [String: Any] = ["type": "function"]
            for (key, value) in function { converted[key] = value }
            return converted
        }
    }

    // MARK: - Transport

    private static func authorize(_ request: inout URLRequest, _ credentials: OAuthCredentials) {
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
    }

    /// Send with a fresh token; on 401, force one refresh and retry (the token may have been
    /// revoked or rotated server-side before its stated expiry).
    private static func send(_ makeRequest: (OAuthCredentials) -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var credentials = try await OAuthTokenStore.shared.freshCredentials(for: provider)
        for attempt in 0..<2 {
            let (data, response) = try await URLSession.shared.data(for: makeRequest(credentials))
            guard let http = response as? HTTPURLResponse else { throw ChatGPTSubscriptionError.noResponse }
            if http.statusCode == 401, attempt == 0 {
                credentials = try await OAuthTokenStore.shared.freshCredentials(for: provider, force: true)
                continue
            }
            guard (200...299).contains(http.statusCode) else {
                // A 401 that survives a successful forced refresh isn't an expired sign-in (a dead
                // refresh token already failed with invalid_grant and signed out). It's the backend
                // refusing this account or request, e.g. a plan without Codex access, so report
                // what it said instead of "sign-in expired".
                let detail = errorDetail(data) ?? "HTTP \(http.statusCode)"
                NSLog("[ChatGPT] request failed: %@", detail)
                throw ChatGPTSubscriptionError.api(detail)
            }
            return (data, http)
        }
        throw OAuthError.authorizationExpired
    }

    /// `{"detail": "…"}` (FastAPI-style, what this backend returns) or `{"error":{"message":…}}`.
    private static func errorDetail(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = json["detail"] as? String { return detail }
        return (json["error"] as? [String: Any])?["message"] as? String
    }
}

enum ChatGPTSubscriptionError: LocalizedError {
    case noResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noResponse: return "No response from ChatGPT."
        case .api(let detail): return "ChatGPT error: \(detail)"
        }
    }
}
