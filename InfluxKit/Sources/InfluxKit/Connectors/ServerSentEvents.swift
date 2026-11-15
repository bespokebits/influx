import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One thing a server-sent event stream (`text/event-stream`) says, as
/// the HTML standard's parsing rules read it.
public enum ServerSentEvent: Sendable, Hashable {
    /// An event: its `event:` name ("message" when it named none) and its
    /// `data:` lines joined by line feeds.
    case event(name: String, data: String)
    /// A `retry:` field: how long to wait before connecting again.
    case retry(milliseconds: Int)
    /// A comment line (`: keepalive`), without its colon and one space.
    case comment(String)
}

/// Reads a `text/event-stream` body as its bytes arrive, in chunks of any
/// size: lines end with CRLF, LF or CR, even when a chunk ends between a
/// CR and its LF; a leading byte order mark is dropped; an event is sent
/// at the blank line that ends it, and one cut off by the end of the
/// stream is not. `id:` fields and unknown fields are ignored.
public struct ServerSentEventParser: Sendable {
    /// The longest line, or event, read before the stream is given up as
    /// not what it says it is. The change stream's are a few dozen bytes.
    public static let maxBytes = 64 * 1024

    /// A line or an event longer than `maxBytes`.
    public struct TooLong: Error, Sendable, Hashable {}

    private var line: [UInt8] = []
    private var afterCR = false
    private var atStart = true
    private var name = ""
    private var data = ""

    public init() {}

    /// What `bytes`, the next part of the body, completes.
    public mutating func push(_ bytes: some Sequence<UInt8>) throws(TooLong) -> [ServerSentEvent] {
        var out: [ServerSentEvent] = []
        for byte in bytes {
            if afterCR {
                afterCR = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0A:
                try endLine(&out)
            case 0x0D:
                try endLine(&out)
                afterCR = true
            default:
                line.append(byte)
                guard line.count <= Self.maxBytes else { throw TooLong() }
            }
        }
        return out
    }

    private mutating func endLine(_ out: inout [ServerSentEvent]) throws(TooLong) {
        var bytes = line[...]
        line.removeAll(keepingCapacity: true)
        if atStart {
            atStart = false
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        }
        guard !bytes.isEmpty else { return dispatch(&out) }
        let text = String(decoding: bytes, as: UTF8.self)
        if text.hasPrefix(":") {
            out.append(.comment(Self.droppingOneSpace(text.dropFirst())))
            return
        }
        let field: Substring, value: String
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = Self.droppingOneSpace(text[text.index(after: colon)...])
        } else {
            field = text[...]
            value = ""
        }
        switch field {
        case "event":
            name = value
        case "data":
            data += value
            data += "\n"
            guard data.utf8.count <= Self.maxBytes else { throw TooLong() }
        case "retry":
            if !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }), let milliseconds = Int(value) {
                out.append(.retry(milliseconds: milliseconds))
            }
        default:
            // `id` (this reader keeps no last event ID) and unknown fields.
            break
        }
    }

    /// The blank line: sends the event gathered since the last one, if it
    /// had any data, and starts the next.
    private mutating func dispatch(_ out: inout [ServerSentEvent]) {
        defer {
            name = ""
            data = ""
        }
        guard !data.isEmpty else { return }
        out.append(.event(name: name.isEmpty ? "message" : name, data: String(data.dropLast())))
    }

    private static func droppingOneSpace(_ text: Substring) -> String {
        String(text.hasPrefix(" ") ? text.dropFirst() : text)
    }
}

/// What an event stream's connection sends up.
public enum EventStreamChunk: Sendable {
    /// The response's status and headers, first and once.
    case response(HTTPURLResponse)
    /// The next bytes of the body, as they arrive.
    case bytes(Data)
}

/// Opens a long-lived HTTP response and hands up its body as it arrives.
/// The app's uses `URLSession`, whose streaming delegate Linux Foundation
/// may lack, so InfluxKit only knows this.
public protocol EventStreamTransport: Sendable {
    /// Sends `request` as it is, following no redirect, and ends a
    /// connection that sends nothing for the request's `timeoutInterval`.
    /// The stream yields `.response` first, then the body's bytes; it
    /// finishes when the server ends the body and throws when the
    /// connection fails. Ending iteration closes the connection.
    func open(_ request: URLRequest) -> AsyncThrowingStream<EventStreamChunk, any Error>
}
