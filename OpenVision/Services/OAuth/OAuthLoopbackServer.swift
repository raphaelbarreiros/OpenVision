// OpenVision - OAuthLoopbackServer.swift
// One-shot HTTP listener on the loopback interface that catches the OAuth redirect.
//
// The CLI client ids we reuse only accept an `http://localhost:<port>/…` redirect, and
// ASWebAuthenticationSession can only hand a custom-scheme (or associated-domain https) callback
// back to the app. So, like the CLIs, we listen on the loopback port ourselves: the login sheet's
// browser loads the redirect, we read `code` + `state` from the request line, answer with a small
// "you can close this" page, and OAuthSignIn dismisses the sheet. The app is frontmost (it's
// presenting the sheet), so the listener is alive for the whole flow.

import Foundation
import Network

final class OAuthLoopbackServer: @unchecked Sendable {

    private let port: UInt16
    private let path: String
    private let expectedState: String
    private let queue = DispatchQueue(label: "openvision.oauth.loopback")
    private var listener: NWListener?
    private var onCallback: (([URLQueryItem]) -> Void)?
    private var delivered = false

    init(port: UInt16, path: String, expectedState: String) {
        self.port = port
        self.path = path
        self.expectedState = expectedState
    }

    /// Bind the port and start accepting. `onCallback` fires once, on an internal queue, with the
    /// query items of the first request on the callback path that carries our `state`.
    /// `onFailure` fires if the listener fails after starting: NWListener's init usually succeeds
    /// even when the port is taken, and the bind error (EADDRINUSE) only arrives later as `.failed`.
    func start(onCallback: @escaping ([URLQueryItem]) -> Void,
               onFailure: @escaping (OAuthError) -> Void) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw OAuthError.portUnavailable(port) }
        let parameters = NWParameters.tcp
        // Loopback only — the redirect never needs to be reachable from the network.
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: nwPort)
        } catch {
            throw OAuthError.portUnavailable(port)
        }
        self.onCallback = onCallback
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
        listener.stateUpdateHandler = { [port] state in
            if case .failed(let error) = state {
                NSLog("[OAuth] loopback listener on %d failed: %@", Int(port), "\(error)")
                onFailure(.portUnavailable(port))
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.onCallback = nil
        }
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            // Only the request line matters; wait for the end of the headers (or give up).
            if buffer.range(of: Data("\r\n\r\n".utf8)) == nil, !isComplete, error == nil, buffer.count < 64 * 1024 {
                self.receiveRequest(on: connection, buffer: buffer)
                return
            }
            self.respond(to: buffer, on: connection)
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let status: String
        let body: String
        switch Self.match(request, expectedPath: path, expectedState: expectedState) {
        case .callback(let query):
            status = "200 OK"
            body = "<html><body style=\"font-family:-apple-system;text-align:center;padding-top:30vh\">"
                + "<h2>Signed in</h2><p>You can return to OpenVision.</p></body></html>"
            if !delivered {
                delivered = true
                onCallback?(query)
            }
        case .wrongState:
            // A prefetch or stray navigation must not use up the one-shot slot, or the real
            // redirect that follows is ignored and the user has to retry.
            status = "400 Bad Request"
            body = "This sign-in link doesn't match the current request."
        case .notCallback:
            status = "404 Not Found"
            body = "Not found"
        }
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    enum Match: Equatable {
        case callback([URLQueryItem])
        case wrongState
        case notCallback
    }

    /// Classify a request: our callback (path and `state` match), the callback path with some
    /// other state, or anything else.
    static func match(_ request: Data, expectedPath: String, expectedState: String) -> Match {
        guard let query = callbackQuery(fromRequest: request, expectedPath: expectedPath) else { return .notCallback }
        return query.first { $0.name == "state" }?.value == expectedState ? .callback(query) : .wrongState
    }

    /// Query items from an HTTP request whose request-line path is `expectedPath`, else nil.
    static func callbackQuery(fromRequest request: Data, expectedPath: String) -> [URLQueryItem]? {
        guard let text = String(data: request, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])),
              components.path == expectedPath else { return nil }
        return components.queryItems ?? []
    }
}
