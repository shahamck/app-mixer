import Foundation
import Network

struct BrowserTab: Identifiable, Codable, Equatable {
    let id: Int
    var title: String
    var host: String?
    var favicon: String?
    var playing: Bool
    var volume: Float
    var muted: Bool
}

struct TabCommand: Codable {
    var volume: Float
    var muted: Bool
}

private struct SyncRequest: Decodable {
    let browser: String
    let tabs: [BrowserTab]
}

/// Tiny HTTP server on 127.0.0.1:47300. The AppMixer Tabs browser extension POSTs its tab list
/// to /sync about once a second and gets back any volume changes made in the menu bar.
@MainActor
final class TabBridge: ObservableObject {
    static let port: NWEndpoint.Port = 47300

    /// Browser bundle ID → tabs reported by its extension.
    @Published private(set) var tabs: [String: [BrowserTab]] = [:]
    private var lastSeen: [String: Date] = [:]
    private var pending: [String: [Int: TabCommand]] = [:]
    private var listener: NWListener?
    private var sweeper: Timer?

    init() {
        start()
        sweeper = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.dropStaleBrowsers() }
        }
    }

    func tabs(for bundleID: String) -> [BrowserTab] { tabs[bundleID] ?? [] }

    func set(browser: String, tab: Int, volume: Float, muted: Bool) {
        pending[browser, default: [:]][tab] = TabCommand(volume: volume, muted: muted)
        // Show the change right away; the extension confirms on its next sync.
        if let i = tabs[browser]?.firstIndex(where: { $0.id == tab }) {
            tabs[browser]?[i].volume = volume
            tabs[browser]?[i].muted = muted
        }
    }

    // MARK: Server

    private func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: Self.port)
        params.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: params) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func dropStaleBrowsers() {
        let now = Date()
        for (browser, seen) in lastSeen where now.timeIntervalSince(seen) > 5 {
            tabs[browser] = nil
            lastSeen[browser] = nil
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                if let request = HTTPRequest(buffer) {
                    self.respond(to: request, on: connection)
                } else if done || error != nil || buffer.count > 1_000_000 {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        // Only the extension may talk to us. Web pages always send their own Origin, which we refuse.
        let origin = request.headers["origin"]
        let fromExtension = origin.map { o in
            ["chrome-extension://", "safari-web-extension://", "moz-extension://"].contains { o.hasPrefix($0) }
        } ?? true
        guard fromExtension else { return send(403, body: Data(), origin: nil, on: connection) }

        if request.method == "OPTIONS" { return send(204, body: Data(), origin: origin, on: connection) }
        if request.method == "GET", request.path == "/status", origin == nil {
            // Local debugging: which browsers have synced, and their tabs.
            let status = tabs.mapValues { $0.map { ["title": $0.title, "playing": $0.playing ? "yes" : "no"] } }
            let body = (try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            return send(200, body: body, origin: nil, on: connection)
        }
        guard request.method == "POST", request.path == "/sync",
              let sync = try? JSONDecoder().decode(SyncRequest.self, from: request.body)
        else { return send(404, body: Data(), origin: origin, on: connection) }

        let commands = pending.removeValue(forKey: sync.browser) ?? [:]
        var reported = sync.tabs
        for i in reported.indices {
            if let cmd = commands[reported[i].id] {
                reported[i].volume = cmd.volume
                reported[i].muted = cmd.muted
            }
        }
        if tabs[sync.browser] != reported { tabs[sync.browser] = reported.isEmpty ? nil : reported }
        lastSeen[sync.browser] = Date()

        let payload = ["commands": Dictionary(uniqueKeysWithValues: commands.map { (String($0.key), $0.value) })]
        let body = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
        send(200, body: body, origin: origin, on: connection)
    }

    private func send(_ status: Int, body: Data, origin: String?, on connection: NWConnection) {
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Status")\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if let origin {
            head += "Access-Control-Allow-Origin: \(origin)\r\nAccess-Control-Allow-Methods: POST\r\n"
            head += "Access-Control-Allow-Headers: Content-Type\r\n"
        }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// Just enough HTTP/1.1 parsing for one request with a Content-Length body.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(_ data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        method = String(start[0])
        path = String(start[1])
        self.headers = headers
        body = data[bodyStart..<(bodyStart + length)]
    }
}
