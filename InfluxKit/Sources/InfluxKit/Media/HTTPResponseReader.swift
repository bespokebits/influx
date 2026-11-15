import Foundation

/// Reads an HTTP/1.1 response from the bytes of a connection, for lookups
/// that make their own connections: the status, the headers, and the body
/// up to a limit, undoing chunked transfer encoding.
struct HTTPResponseReader {
    /// The most the status line and headers may take.
    static let headLimit = 64 * 1024

    struct Malformed: Error {}

    let limit: Int
    private(set) var status: Int?
    private(set) var headers: [String: String] = [:]
    private(set) var body = Data()
    /// Whether everything wanted has been read: the whole body, or the limit.
    private(set) var isDone = false

    private var head = Data()
    private var informational = 0
    /// Informational responses allowed before the final one.
    static let informationalLimit = 8
    private var framing = Framing.untilClose

    private enum Framing {
        case untilClose
        case length(remaining: Int)
        case chunked(Chunk)
    }

    private enum Chunk {
        case size(line: Data)
        case data(remaining: Int)
        case dataEnd(seen: Int)
    }

    init(limit: Int) {
        self.limit = limit
    }

    /// Takes the next bytes the connection delivered.
    mutating func feed(_ data: Data) throws {
        guard !isDone else { return }
        var bytes = data[...]
        if status == nil {
            head.append(bytes)
            // Informational responses such as 103 Early Hints come first
            // and are skipped; the final response follows them.
            while true {
                guard let end = head.range(of: Data("\r\n\r\n".utf8)) else {
                    guard head.count <= Self.headLimit else { throw Malformed() }
                    return
                }
                let isFinal = try parseHead(head[..<end.lowerBound])
                head = Data(head[end.upperBound...])
                if isFinal { break }
                informational += 1
                guard informational <= Self.informationalLimit else { throw Malformed() }
            }
            bytes = head[...]
            head = Data()
        }
        try readBody(bytes)
    }

    /// The connection closed: a body read to its close is complete, one
    /// cut short of its stated length or last chunk is not.
    mutating func finish() throws {
        guard !isDone else { return }
        guard status != nil, case .untilClose = framing else { throw Malformed() }
        isDone = true
    }

    /// Reads a response head; false for an informational one, which is
    /// dropped.
    private mutating func parseHead(_ text: Data) throws -> Bool {
        let lines = String(decoding: text, as: UTF8.self).components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ", maxSplits: 2)
        guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let code = Int(statusLine[1]), (100...599).contains(code) else {
            throw Malformed()
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Malformed() }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[name] = fields[name].map { "\($0), \(value)" } ?? value
        }
        // 101 switches protocol, so nothing HTTP follows it.
        if (100..<200).contains(code), code != 101 {
            return false
        }
        headers = fields
        status = code
        if code == 204 || code == 304 || (100..<200).contains(code) {
            isDone = true
        } else if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            framing = .chunked(.size(line: Data()))
        } else if let length = headers["content-length"] {
            guard let count = Int(length), count >= 0 else { throw Malformed() }
            framing = .length(remaining: count)
            if count == 0 { isDone = true }
        }
        return true
    }

    private mutating func readBody(_ bytes: Data.SubSequence) throws {
        var bytes = bytes
        while !bytes.isEmpty, !isDone {
            switch framing {
            case .untilClose:
                take(&bytes, bytes.count)
            case .length(let remaining):
                let taken = take(&bytes, remaining)
                framing = .length(remaining: remaining - taken)
                if remaining == taken { isDone = true }
            case .chunked(.size(var line)):
                let byte = bytes.removeFirst()
                guard byte != UInt8(ascii: "\n") else {
                    // The size is hex, before any ";extension".
                    let text = String(decoding: line, as: UTF8.self).split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
                    guard let size = Int(text, radix: 16), size >= 0 else { throw Malformed() }
                    if size == 0 {
                        isDone = true
                    } else {
                        framing = .chunked(.data(remaining: size))
                    }
                    continue
                }
                if byte != UInt8(ascii: "\r") { line.append(byte) }
                guard line.count <= 1024 else { throw Malformed() }
                framing = .chunked(.size(line: line))
            case .chunked(.data(let remaining)):
                let taken = take(&bytes, remaining)
                framing = .chunked(remaining == taken ? .dataEnd(seen: 0) : .data(remaining: remaining - taken))
            case .chunked(.dataEnd(let seen)):
                let byte = bytes.removeFirst()
                guard byte == (seen == 0 ? UInt8(ascii: "\r") : UInt8(ascii: "\n")) else { throw Malformed() }
                framing = .chunked(seen == 0 ? .dataEnd(seen: 1) : .size(line: Data()))
            }
        }
    }

    /// Moves up to `count` bytes into the body, stopping at the limit.
    @discardableResult
    private mutating func take(_ bytes: inout Data.SubSequence, _ count: Int) -> Int {
        let taken = min(count, bytes.count)
        let kept = min(taken, limit - body.count)
        body.append(bytes.prefix(kept))
        bytes = bytes.dropFirst(taken)
        if body.count >= limit { isDone = true }
        return taken
    }
}
