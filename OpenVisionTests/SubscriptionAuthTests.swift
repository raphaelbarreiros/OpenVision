// OpenVision - SubscriptionAuthTests.swift
// The pure parts of subscription sign-in (PKCE, callback/state checks, token + JWT parsing) and
// the ChatGPT backend's wire format (SSE items, model list, tool conversion).

import XCTest
@testable import OpenVision

final class SubscriptionAuthTests: XCTestCase {

    private let provider = ChatGPTSubscription.provider

    // MARK: - PKCE

    func testChallengeMatchesRFC7636Vector() {
        XCTAssertEqual(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testRandomStringIsURLSafeAndUnique() {
        let a = PKCE.randomString(), b = PKCE.randomString()
        XCTAssertNotEqual(a, b)
        XCTAssertNil(a.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertGreaterThanOrEqual(a.count, 43, "RFC 7636 verifiers are at least 43 chars")
    }

    // MARK: - Authorize URL + callback

    func testAuthorizeURLCarriesPKCEAndProviderParams() {
        let url = OAuthClient.authorizeURL(for: provider, challenge: "CH", state: "ST")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(value("code_challenge"), "CH")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("state"), "ST")
        XCTAssertEqual(value("redirect_uri"), "http://localhost:1455/auth/callback")
        XCTAssertEqual(value("originator"), "codex_cli_rs")
    }

    func testCallbackRejectsWrongState() {
        let query = [URLQueryItem(name: "code", value: "abc"), URLQueryItem(name: "state", value: "other")]
        XCTAssertThrowsError(try OAuthClient.authorizationCode(from: query, expectedState: "mine")) {
            XCTAssertEqual($0 as? OAuthError, .stateMismatch)
        }
    }

    func testCallbackSurfacesProviderError() {
        let query = [URLQueryItem(name: "error", value: "access_denied"),
                     URLQueryItem(name: "error_description", value: "User declined")]
        XCTAssertThrowsError(try OAuthClient.authorizationCode(from: query, expectedState: "s")) {
            XCTAssertEqual($0 as? OAuthError, .provider("User declined"))
        }
    }

    func testCallbackReturnsCode() throws {
        let query = [URLQueryItem(name: "code", value: "abc"), URLQueryItem(name: "state", value: "s")]
        XCTAssertEqual(try OAuthClient.authorizationCode(from: query, expectedState: "s"), "abc")
    }

    func testLoopbackParsesOnlyTheCallbackPath() {
        let hit = Data("GET /auth/callback?code=c1&state=s1 HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)
        let items = OAuthLoopbackServer.callbackQuery(fromRequest: hit, expectedPath: "/auth/callback")
        XCTAssertEqual(items?.first { $0.name == "code" }?.value, "c1")

        let favicon = Data("GET /favicon.ico HTTP/1.1\r\n\r\n".utf8)
        XCTAssertNil(OAuthLoopbackServer.callbackQuery(fromRequest: favicon, expectedPath: "/auth/callback"))
    }

    func testLoopbackOnlyAcceptsOurState() {
        let ours = Data("GET /auth/callback?code=c1&state=s1 HTTP/1.1\r\n\r\n".utf8)
        let stray = Data("GET /auth/callback?code=c0&state=old HTTP/1.1\r\n\r\n".utf8)
        let other = Data("GET /favicon.ico HTTP/1.1\r\n\r\n".utf8)
        guard case .callback = OAuthLoopbackServer.match(ours, expectedPath: "/auth/callback", expectedState: "s1") else {
            return XCTFail("our redirect must be delivered")
        }
        XCTAssertEqual(OAuthLoopbackServer.match(stray, expectedPath: "/auth/callback", expectedState: "s1"), .wrongState)
        XCTAssertEqual(OAuthLoopbackServer.match(other, expectedPath: "/auth/callback", expectedState: "s1"), .notCallback)
    }

    // MARK: - Spoken length

    func testShortRepliesAreNotCapped() {
        XCTAssertEqual(ChatGPTSubscription.capForSpeech("Short answer."), "Short answer.")
    }

    func testLongRepliesAreCutAtASentence() {
        let sentence = String(repeating: "word ", count: 40).trimmingCharacters(in: .whitespaces) + "."
        let reply = Array(repeating: sentence, count: 20).joined(separator: " ")
        let capped = ChatGPTSubscription.capForSpeech(reply)
        XCTAssertLessThanOrEqual(capped.count, ChatGPTSubscription.maxSpokenCharacters)
        XCTAssertTrue(capped.hasSuffix("."), "cut at a sentence boundary")
        XCTAssertTrue(reply.hasPrefix(capped))
    }

    // MARK: - Tokens

    func testCredentialsApplySkewAndReadAccountId() throws {
        let idToken = jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct_123"]])
        let json = try JSONSerialization.data(withJSONObject: [
            "access_token": "AT", "refresh_token": "RT", "id_token": idToken, "expires_in": 3600,
        ])
        let now = Date(timeIntervalSince1970: 1_000)
        let creds = try OAuthClient.credentials(from: json, provider: provider, previous: nil, now: now)
        XCTAssertEqual(creds.accessToken, "AT")
        XCTAssertEqual(creds.refreshToken, "RT")
        XCTAssertEqual(creds.accountId, "acct_123")
        XCTAssertEqual(creds.expiresAt, now.addingTimeInterval(3600 - provider.refreshSkew))
    }

    func testRefreshKeepsPreviousRefreshTokenAndAccount() throws {
        let previous = OAuthCredentials(accessToken: "old", refreshToken: "RT1", expiresAt: .distantPast, accountId: "acct")
        let json = try JSONSerialization.data(withJSONObject: ["access_token": "new", "expires_in": 60])
        let creds = try OAuthClient.credentials(from: json, provider: provider, previous: previous)
        XCTAssertEqual(creds.refreshToken, "RT1")
        XCTAssertEqual(creds.accountId, "acct")
    }

    func testMissingAccessTokenThrows() {
        let json = Data(#"{"refresh_token":"RT"}"#.utf8)
        XCTAssertThrowsError(try OAuthClient.credentials(from: json, provider: provider, previous: nil))
    }

    func testAccountIdFallsBackToOrganization() {
        XCTAssertEqual(JWT.chatGPTAccountId(idToken: jwt(["organizations": [["id": "org_1"]]]), accessToken: nil), "org_1")
        XCTAssertNil(JWT.chatGPTAccountId(idToken: "not-a-jwt", accessToken: nil))
    }

    // MARK: - Refresh failures

    func testTokenErrorCodeReadsFlatAndNestedForms() {
        XCTAssertEqual(OAuthClient.tokenErrorCode(Data(#"{"error":"invalid_grant"}"#.utf8)), "invalid_grant")
        // OpenAI's token endpoint nests it (shape from the Codex CLI's tests).
        let nested = #"{"error":{"message":"Your refresh token has already been used.","type":"invalid_request_error","code":"refresh_token_reused"}}"#
        XCTAssertEqual(OAuthClient.tokenErrorCode(Data(nested.utf8)), "refresh_token_reused")
        XCTAssertNil(OAuthClient.tokenErrorCode(Data("<html>Unauthorized</html>".utf8)))
    }

    func testRevokedRefreshSignsOut() {
        XCTAssertTrue(OAuthClient.isRevoked(status: 400, errorCode: "invalid_grant"))
        XCTAssertTrue(OAuthClient.isRevoked(status: 401, errorCode: "refresh_token_invalidated"))
        XCTAssertTrue(OAuthClient.isRevoked(status: 401, errorCode: "token_revoked"), "a 401 with an OAuth error is permanent")
    }

    func testTransientRefreshFailuresKeepTheSignIn() {
        XCTAssertFalse(OAuthClient.isRevoked(status: 401, errorCode: nil), "bare 401, e.g. from a proxy")
        XCTAssertFalse(OAuthClient.isRevoked(status: 401, errorCode: "invalid_client"))
        XCTAssertFalse(OAuthClient.isRevoked(status: 500, errorCode: "server_error"))
        XCTAssertFalse(OAuthClient.isRevoked(status: 503, errorCode: nil))
    }

    func testFormEncodingEscapesReservedCharacters() {
        XCTAssertEqual(OAuthClient.formEncode(["refresh_token": "a+b/c=d&e"]), "refresh_token=a%2Bb%2Fc%3Dd%26e")
    }

    // MARK: - ChatGPT backend wire format

    func testStreamCollectsOutputItemsNotCompleted() {
        // Shape captured from the live backend: items arrive as output_item.done; completed is empty.
        let sse = """
        event: response.created
        data: {"type":"response.created","response":{"id":"r1","output":[]}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"function_call","name":"web_search","call_id":"c1","arguments":"{\\"query\\":\\"x\\"}"}}

        event: response.output_item.done
        data: {"type":"response.output_item.done","item":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hi"}]}}

        event: response.completed
        data: {"type":"response.completed","response":{"id":"r1","output":[]}}

        """
        let (items, error) = ChatGPTSubscription.parseStream(Data(sse.utf8))
        XCTAssertNil(error)
        XCTAssertEqual(items.compactMap { $0["type"] as? String }, ["function_call", "message"])
    }

    func testStreamReportsFailure() {
        let sse = #"data: {"type":"response.failed","response":{"error":{"message":"rate limited"}}}"#
        XCTAssertEqual(ChatGPTSubscription.parseStream(Data(sse.utf8)).error, "rate limited")
    }

    func testModelsSkipHiddenAndTextOnly() throws {
        let json = try JSONSerialization.data(withJSONObject: ["models": [
            ["slug": "gpt-6-luna", "display_name": "GPT-6-Luna", "visibility": "list", "input_modalities": ["text", "image"]],
            ["slug": "gpt-reserve", "visibility": "hide", "input_modalities": ["text", "image"]],
            ["slug": "text-only", "visibility": "list", "input_modalities": ["text"]],
        ]])
        XCTAssertEqual(ChatGPTSubscription.parseModels(json).map(\.slug), ["gpt-6-luna"])
    }

    func testChatToolsConvertToResponsesFormat() {
        let chat: [[String: Any]] = [["type": "function", "function": ["name": "web_search", "parameters": ["type": "object"]]]]
        let tool = ChatGPTSubscription.responsesTools(fromChatTools: chat).first
        XCTAssertEqual(tool?["type"] as? String, "function")
        XCTAssertEqual(tool?["name"] as? String, "web_search")
        XCTAssertNotNil(tool?["parameters"])
    }

    // MARK: - Helpers

    private func jwt(_ claims: [String: Any]) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: claims).base64URLEncoded
        return "eyJhbGciOiJub25lIn0.\(payload).sig"
    }
}
