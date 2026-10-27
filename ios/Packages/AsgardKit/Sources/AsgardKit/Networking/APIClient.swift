import Foundation

public struct APIError: Error, LocalizedError, Sendable {
    public var status: Int
    public var code: String
    public var message: String
    public var details: JSONValue?
    public var errorDescription: String? { message }

    public static let offline = APIError(status: 0, code: "offline", message: "You're offline. Messages will send when you reconnect.")
}

/// Thin async wrapper around the Asgard REST API.
public final class APIClient: Sendable {
    public let baseURL: URL
    public let token: String?
    let session: URLSession

    public init(baseURL: URL, token: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func with(token: String) -> APIClient { APIClient(baseURL: baseURL, token: token, session: session) }

    func request(_ method: String, _ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var comps = URLComponents(url: baseURL.appending(path: "api/v1" + path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    @discardableResult
    public func send<Out: Decodable & Sendable>(_ method: String, _ path: String, query: [URLQueryItem] = [], body: (some Encodable & Sendable)? = nil as Empty?,
                                                as: Out.Type = Out.self) async throws -> Out {
        var req = request(method, path, query: query)
        if let body {
            req.httpBody = try Coding.encoder.encode(body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(req)
    }

    public func call(_ method: String, _ path: String, body: (some Encodable & Sendable)? = nil as Empty?) async throws {
        let _: Empty = try await send(method, path, body: body)
    }

    func perform<Out: Decodable>(_ req: URLRequest) async throws -> Out {
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let error as URLError where [.notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut, .cannotFindHost].contains(error.code) {
            throw APIError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if let body = try? Coding.decoder.decode(APIErrorBody.self, from: data) {
                throw APIError(status: status, code: body.error.code, message: body.error.message, details: body.error.details)
            }
            throw APIError(status: status, code: "http_\(status)", message: HTTPURLResponse.localizedString(forStatusCode: status).capitalized)
        }
        if Out.self == Empty.self || data.isEmpty { return Empty() as! Out }
        return try Coding.decoder.decode(Out.self, from: data)
    }

    // MARK: Media

    public func upload(_ blob: Data, purpose: String? = nil, contentType: String = "application/octet-stream", ttl: Int? = nil) async throws -> UUID {
        var items: [URLQueryItem] = []
        if let purpose { items.append(.init(name: "purpose", value: purpose)) }
        if let ttl { items.append(.init(name: "ttl", value: String(ttl))) }
        var req = request("POST", "/media", query: items)
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600
        let (data, response) = try await session.upload(for: req, from: blob)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 201 else {
            let body = try? Coding.decoder.decode(APIErrorBody.self, from: data)
            throw APIError(status: status, code: body?.error.code ?? "upload_failed", message: body?.error.message ?? "Upload failed.")
        }
        struct Out: Decodable { var id: UUID }
        return try Coding.decoder.decode(Out.self, from: data).id
    }

    public func download(_ mediaID: UUID) async throws -> Data {
        var req = request("GET", "/media/\(mediaID.lower)")
        req.timeoutInterval = 600
        let (data, response) = try await session.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw APIError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: "download_failed", message: "Couldn't download media.")
        }
        return data
    }

    public func mediaURL(_ id: UUID) -> URL { baseURL.appending(path: "api/v1/media/\(id.lower)") }

    public var webSocketURL: URL {
        var comps = URLComponents(url: baseURL.appending(path: "api/v1/ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "http" ? "ws" : "wss"
        return comps.url!
    }
}

public struct Empty: Codable, Sendable {
    public init() {}
}

// MARK: - Typed endpoints

public struct DeviceRegistration: Codable, Sendable {
    public var name: String
    public var platform: String
    public var identityKey: Data
    public var signingKey: Data
    enum CodingKeys: String, CodingKey { case name, platform, identityKey = "identity_key", signingKey = "signing_key" }
    public init(name: String, platform: String, keys: DeviceKeys) {
        self.name = name; self.platform = platform; identityKey = keys.identityPublic; signingKey = keys.signingPublic
    }
}

extension APIClient {
    public func info() async throws -> ServerInfo { try await send("GET", "/info") }

    public func register(invite: String, username: String, password: String, displayName: String, device: DeviceRegistration) async throws -> Session {
        struct Body: Encodable, Sendable { var invite, username, password, display_name: String; var device: DeviceRegistration }
        return try await send("POST", "/auth/register", body: Body(invite: invite, username: username, password: password, display_name: displayName, device: device))
    }

    public func login(username: String, password: String, device: DeviceRegistration) async throws -> Session {
        struct Body: Encodable, Sendable { var username, password: String; var device: DeviceRegistration }
        return try await send("POST", "/auth/login", body: Body(username: username, password: password, device: device))
    }

    public func claimLink(code: String, device: DeviceRegistration) async throws -> Session {
        struct Body: Encodable, Sendable { var code: String; var device: DeviceRegistration }
        return try await send("POST", "/devices/link/claim", body: Body(code: code, device: device))
    }

    public func conversations() async throws -> [Conversation] { try await send("GET", "/conversations") }
    public func conversation(_ id: UUID) async throws -> Conversation { try await send("GET", "/conversations/\(id.lower)") }
    public func devices(in conversation: UUID) async throws -> [DeviceInfo] { try await send("GET", "/conversations/\(conversation.lower)/devices") }
    public func devices(of user: UUID) async throws -> [DeviceInfo] { try await send("GET", "/users/\(user.lower)/devices") }
    public func members(of conversation: UUID) async throws -> [Member] { try await send("GET", "/conversations/\(conversation.lower)/members") }

    public func sync(after cursor: Int64) async throws -> SyncPage {
        try await send("GET", "/sync", query: [.init(name: "after", value: String(cursor))])
    }

    public func history(_ conversation: UUID, before seq: Int64?, limit: Int = 50) async throws -> [Envelope] {
        var q = [URLQueryItem(name: "limit", value: String(limit))]
        if let seq { q.append(.init(name: "before_seq", value: String(seq))) }
        return try await send("GET", "/conversations/\(conversation.lower)/messages", query: q)
    }
}
