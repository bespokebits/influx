import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why a fetch or action failed. Each case shows as a quiet state on the
/// source (`SourceProblem`), never as a modal.
public enum ConnectorError: Error, Sendable, Hashable {
    /// The request never got an answer: no network, a timeout, DNS.
    case offline
    /// The credentials were refused; the account needs signing in again.
    case unauthorized
    /// The service asked us to slow down, until `retryAfter` if it said.
    case rateLimited(retryAfter: Date?)
    /// The source is gone (HTTP 404 or 410).
    case notFound
    /// The service answered with something we can't use: an unexpected
    /// status, or a body that doesn't parse.
    case badResponse(String)
    /// The connector doesn't do this.
    case unsupported

    /// Throws the error an HTTP response stands for, if any. 2xx and 304
    /// pass. `now` dates a `Retry-After` given in seconds.
    public static func check(_ response: HTTPURLResponse, now: Date) throws {
        switch response.statusCode {
        case 200..<300, 304:
            return
        case 401, 403:
            throw ConnectorError.unauthorized
        case 404, 410:
            throw ConnectorError.notFound
        case 429:
            throw ConnectorError.rateLimited(retryAfter: retryAfter(response, now: now))
        case 503 where response.value(forHTTPHeaderField: "Retry-After") != nil:
            throw ConnectorError.rateLimited(retryAfter: retryAfter(response, now: now))
        default:
            throw ConnectorError.badResponse("HTTP \(response.statusCode)")
        }
    }

    /// `Retry-After` as seconds or an HTTP date.
    static func retryAfter(_ response: HTTPURLResponse, now: Date) -> Date? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        if let seconds = TimeInterval(value) {
            return now.addingTimeInterval(max(0, seconds))
        }
        return HTTPDate.parse(value)
    }
}

/// HTTP dates (RFC 9110 IMF-fixdate, e.g. "Sun, 06 Nov 1994 08:49:37 GMT"),
/// as `Retry-After` and `Last-Modified` carry them.
enum HTTPDate {
    static func parse(_ string: String) -> Date? {
        formatter().date(from: string)
    }

    static func format(_ date: Date) -> String {
        formatter().string(from: date)
    }

    // A new formatter per call: headers are rare, and DateFormatter isn't
    // Sendable on every platform.
    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }
}
