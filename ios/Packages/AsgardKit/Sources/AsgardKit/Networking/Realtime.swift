import Foundation

/// One realtime frame from the server. `raw` is the whole frame for typed decoding.
public struct RealtimeEvent: Sendable {
    public let type: String
    public let raw: Data

    public func decode<T: Decodable>(_: T.Type) -> T? {
        (try? Coding.decoder.decode(InboundFrame<T>.self, from: raw))?.data
    }
}

struct InboundFrame<T: Decodable>: Decodable { var data: T }
struct OutboundFrame<D: Encodable>: Encodable { var type: String; var data: D }

public enum ConnectionState: Sendable, Equatable {
    case disconnected, connecting, connected
}

/// WebSocket connection with automatic reconnect and backoff.
public final class RealtimeClient: NSObject, @unchecked Sendable, URLSessionWebSocketDelegate {
    private let url: URL
    private let token: String
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    private let lock = NSLock()
    private var continuation: AsyncStream<RealtimeEvent>.Continuation?
    private var stateContinuation: AsyncStream<ConnectionState>.Continuation?
    private var attempt = 0
    private var stopped = true
    private var pingTask: Task<Void, Never>?

    public let events: AsyncStream<RealtimeEvent>
    public let states: AsyncStream<ConnectionState>

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
        var c: AsyncStream<RealtimeEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(1000)) { c = $0 }
        var s: AsyncStream<ConnectionState>.Continuation!
        states = AsyncStream(bufferingPolicy: .bufferingNewest(10)) { s = $0 }
        super.init()
        continuation = c
        stateContinuation = s
    }

    public func start() {
        lock.withLock { stopped = false }
        connect()
    }

    public func stop() {
        lock.withLock {
            stopped = true
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            pingTask?.cancel()
        }
        stateContinuation?.yield(.disconnected)
    }

    public func send(type: String, data: some Encodable & Sendable) {
        guard let body = try? Coding.encoder.encode(OutboundFrame(type: type, data: data)), let text = String(data: body, encoding: .utf8) else { return }
        lock.withLock { task }?.send(.string(text)) { _ in }
    }

    private func connect() {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 20
        let t = session.webSocketTask(with: req)
        lock.withLock {
            guard !stopped else { return }
            task = t
        }
        stateContinuation?.yield(.connecting)
        t.resume()
        receive(on: t)
    }

    private func receive(on t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let msg):
                var data: Data?
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let type = Self.frameType(data) {
                    if type == "hello" {
                        self.lock.withLock { self.attempt = 0 }
                        self.stateContinuation?.yield(.connected)
                    }
                    self.continuation?.yield(RealtimeEvent(type: type, raw: data))
                }
                self.receive(on: t)
            case .failure:
                self.scheduleReconnect(failed: t)
            }
        }
    }

    private static func frameType(_ data: Data) -> String? {
        struct Head: Decodable { var type: String }
        return (try? JSONDecoder().decode(Head.self, from: data))?.type
    }

    private func scheduleReconnect(failed t: URLSessionWebSocketTask) {
        let delay: Double? = lock.withLock {
            guard !stopped, task === t else { return nil }
            task = nil
            attempt += 1
            return min(30, pow(2, Double(min(attempt, 5)))) * Double.random(in: 0.7...1.3)
        }
        stateContinuation?.yield(.disconnected)
        guard let delay else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.connect()
        }
    }

    /// Call when the network path changes or the app returns to foreground.
    public func reconnectNow() {
        let t: URLSessionWebSocketTask? = lock.withLock {
            attempt = 0
            return task
        }
        if t == nil || t?.state != .running {
            t?.cancel()
            lock.withLock { task = nil }
            connect()
        }
    }
}
