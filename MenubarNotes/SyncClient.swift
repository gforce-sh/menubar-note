import Foundation

struct RemoteNote: Decodable {
    let id: String
    let body: String
    let updatedAt: Int
}

enum SyncError: Error, Equatable {
    /// No session, or the server rejected the one we hold.
    case unauthorized
    /// The remote note is gone; syncing can't continue against this id.
    case notFound
    /// Network unreachable — the caller should fall back to local-only behaviour.
    case offline
    /// The server's global passcode lockout is engaged.
    case locked
    case badPasscode
    case server(Int)
    case malformedResponse
}

/// Talks to the quick-note server.
///
/// Cookies are handled by hand rather than via `HTTPCookieStorage`: the server
/// sets `Secure` on the session cookie whenever `NODE_ENV=production`, and
/// URLSession's jar drops those over plain http, which would break local
/// testing against localhost. We persist the token ourselves anyway.
final class SyncClient {
    private let session: URLSession
    private var config: AppConfig

    init(config: AppConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        session = URLSession(configuration: configuration)
    }

    func update(config: AppConfig) {
        self.config = config
    }

    var hasSession: Bool { SessionStore.load() != nil }

    // MARK: - Requests

    private func url(_ path: String) throws -> URL {
        guard let base = URL(string: config.serverURL),
              let url = URL(string: "/api/v1" + path, relativeTo: base)
        else { throw SyncError.malformedResponse }
        return url
    }

    private func request(_ method: String, _ path: String, body: [String: String]? = nil) throws -> URLRequest {
        var request = URLRequest(url: try url(path))
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        if let token = SessionStore.load() {
            request.setValue("session=\(token)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SyncError.malformedResponse }
            return (data, http)
        } catch let error as SyncError {
            throw error
        } catch {
            // Anything URLSession itself rejects — DNS, refused connection, timeout —
            // is treated as "we're offline", which is the local-only fallback path.
            throw SyncError.offline
        }
    }

    // MARK: - Endpoints

    /// Exchanges the 4-digit passcode for a session cookie.
    ///
    /// Callers must never retry this automatically on `.badPasscode`: the server
    /// keeps a global counter and locks *every* user out for an hour after five
    /// failures.
    func login(passcode: String) async throws {
        let request = try request("POST", "/login", body: ["passcode": passcode])
        let (_, http) = try await send(request)

        switch http.statusCode {
        case 200: break
        case 401: throw SyncError.badPasscode
        case 429: throw SyncError.locked
        default: throw SyncError.server(http.statusCode)
        }

        guard let setCookie = http.value(forHTTPHeaderField: "Set-Cookie"),
              let token = Self.sessionToken(fromSetCookie: setCookie)
        else { throw SyncError.malformedResponse }

        SessionStore.save(token)
    }

    func fetchNote() async throws -> RemoteNote {
        let request = try request("GET", "/notes/\(config.noteID)")
        let (data, http) = try await send(request)

        switch http.statusCode {
        case 200:
            guard let note = try? JSONDecoder().decode(RemoteNote.self, from: data) else {
                throw SyncError.malformedResponse
            }
            return note
        case 401:
            SessionStore.clear()
            throw SyncError.unauthorized
        case 404: throw SyncError.notFound
        default: throw SyncError.server(http.statusCode)
        }
    }

    @discardableResult
    func pushBody(_ body: String) async throws -> RemoteNote {
        let request = try request("PATCH", "/notes/\(config.noteID)", body: ["body": body])
        let (data, http) = try await send(request)

        switch http.statusCode {
        case 200:
            guard let note = try? JSONDecoder().decode(RemoteNote.self, from: data) else {
                throw SyncError.malformedResponse
            }
            return note
        case 401:
            SessionStore.clear()
            throw SyncError.unauthorized
        case 404: throw SyncError.notFound
        default: throw SyncError.server(http.statusCode)
        }
    }

    /// Pulls the `session=` value out of a Set-Cookie header, discarding the
    /// attributes (Secure, HttpOnly, Max-Age) which we don't honour ourselves.
    static func sessionToken(fromSetCookie header: String) -> String? {
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard pair.hasPrefix("session=") else { continue }
            let value = String(pair.dropFirst("session=".count))
            return value.isEmpty ? nil : value
        }
        return nil
    }
}
