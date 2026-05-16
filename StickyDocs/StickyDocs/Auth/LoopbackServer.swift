import Foundation
import Network

// Minimal HTTP-over-TCP listener bound to localhost on an OS-assigned port.
// Captures the first GET request and returns its query parameters.
// Used to receive the OAuth 2.0 redirect on http://localhost:<port>/.
final class LoopbackServer {
    enum LoopbackError: Error, LocalizedError {
        case listenerFailed(Error)
        case noPort
        case malformedRequest

        var errorDescription: String? {
            switch self {
            case .listenerFailed(let err):
                return "Loopback listener failed to start: \(err.localizedDescription) (\(err))"
            case .noPort:
                return "Loopback listener reported no port"
            case .malformedRequest:
                return "Loopback received a malformed HTTP request"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.balenet.StickyDocs.loopback")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var requestContinuation: CheckedContinuation<[String: String], Error>?

    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            self?.handle(connection: conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard let port = listener.port?.rawValue else {
                    self.portContinuation?.resume(throwing: LoopbackError.noPort)
                    self.portContinuation = nil
                    return
                }
                self.portContinuation?.resume(returning: port)
                self.portContinuation = nil
            case .failed(let err):
                self.portContinuation?.resume(throwing: LoopbackError.listenerFailed(err))
                self.portContinuation = nil
                self.requestContinuation?.resume(throwing: LoopbackError.listenerFailed(err))
                self.requestContinuation = nil
            default:
                break
            }
        }

        return try await withCheckedThrowingContinuation { cont in
            self.portContinuation = cont
            listener.start(queue: self.queue)
        }
    }

    func waitForRequest() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            self.requestContinuation = cont
        }
    }

    func stop() {
        connection?.cancel()
        listener?.cancel()
        connection = nil
        listener = nil
    }

    private func handle(connection: NWConnection) {
        self.connection = connection
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            let body = "<html><body><h2>Sign-in complete. You can close this window.</h2></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            guard let data, let request = String(data: data, encoding: .utf8) else {
                self.requestContinuation?.resume(throwing: LoopbackError.malformedRequest)
                self.requestContinuation = nil
                return
            }
            if let params = Self.parseQuery(from: request) {
                self.requestContinuation?.resume(returning: params)
            } else {
                self.requestContinuation?.resume(throwing: LoopbackError.malformedRequest)
            }
            self.requestContinuation = nil
        }
    }

    private static func parseQuery(from rawRequest: String) -> [String: String]? {
        guard let firstLine = rawRequest.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let target = String(parts[1])
        guard let comps = URLComponents(string: "http://localhost" + target) else { return nil }
        var out: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            out[item.name] = item.value ?? ""
        }
        return out
    }
}
