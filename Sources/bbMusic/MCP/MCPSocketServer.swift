import Foundation
import Network

/// Minimal HTTP/1.1 server for the MCP endpoint.
///
/// `NWListener` on loopback only, one request per connection (MCP clients do not need keep-alive for
/// local tool calls), bearer-token authenticated. Deliberately small: no routing table, no static
/// files, no TLS — anything more would be a second web framework inside a music player.
final class MCPSocketServer: @unchecked Sendable {
    private let port: UInt16
    private let token: String
    private let handler: @Sendable (MCPRequest) async -> MCPResponse
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "local.bbmusic.mcp")

    init(port: UInt16, token: String, handler: @escaping @Sendable (MCPRequest) async -> MCPResponse) {
        self.port = port
        self.token = token
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        // Loopback only: this must never be reachable from the network.
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if error != nil || (isComplete && buffer.isEmpty) {
                connection.cancel()
                return
            }
            // Wait for the full head plus any declared body.
            guard let request = MCPRequest.parse(buffer) else {
                self.receive(on: connection, buffer: buffer)
                return
            }
            guard request.isAuthorized(token: self.token) else {
                self.write(MCPResponse.unauthorized(), on: connection)
                return
            }
            if request.method == "GET" {
                // A plain GET is a liveness probe, not an MCP call.
                self.write(.ok(body: Data(#"{"status":"ok"}"#.utf8)), on: connection)
                return
            }
            Task {
                let response = await self.handler(request)
                self.write(response, on: connection)
            }
        }
    }

    private func write(_ response: MCPResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(response.statusText)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var payload = Data(head.utf8)
        payload.append(response.body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Request / response

struct MCPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    func isAuthorized(token: String) -> Bool {
        let header = headers["authorization"] ?? ""
        let provided = header.hasPrefix("Bearer ") ? String(header.dropFirst("Bearer ".count)) : ""
        guard !provided.isEmpty, provided.count == token.count else { return false }
        // Constant-time-ish comparison; this is a loopback token, not a network credential, but
        // there is no reason to leak length-prefix timing.
        return zip(provided.utf8, token.utf8).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Returns nil until the request is complete.
    static func parse(_ data: Data) -> MCPRequest? {
        guard let text = String(data: data, encoding: .utf8),
              let separator = text.range(of: "\r\n\r\n")
        else { return nil }

        let head = String(text[text.startIndex..<separator.lowerBound])
        let body = String(text[separator.upperBound...])
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let declared = Int(headers["content-length"] ?? "0") ?? 0
        guard body.utf8.count >= declared else { return nil }
        // A body longer than declared is truncated, not rejected: clients occasionally pad.
        let bodyData = Data(Array(body.utf8).prefix(declared))
        return MCPRequest(
            method: String(parts[0]),
            path: String(parts[1]),
            headers: headers,
            body: bodyData
        )
    }
}

struct MCPResponse {
    let status: Int
    let body: Data

    var statusText: String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 500: return "Internal Server Error"
        default: return "Unknown"
        }
    }

    static let empty = MCPResponse(status: 200, body: Data())

    static func ok(body: Data) -> MCPResponse { MCPResponse(status: 200, body: body) }

    static func unauthorized() -> MCPResponse {
        MCPResponse(status: 401, body: Data(#"{"error":"unauthorized"}"#.utf8))
    }

    static func error(status: Int, message: String) -> MCPResponse {
        let body = try? JSONSerialization.data(withJSONObject: ["error": message])
        return MCPResponse(status: status, body: body ?? Data())
    }

    static func jsonRPC(id: Any?, result: [String: Any]) -> MCPResponse {
        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        payload["id"] = id ?? NSNull()
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return MCPResponse(status: 200, body: body)
    }

    static func jsonRPC(id: Any?, error message: String) -> MCPResponse {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": -32601, "message": message],
        ]
        payload["id"] = id ?? NSNull()
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        return MCPResponse(status: 200, body: body)
    }
}
