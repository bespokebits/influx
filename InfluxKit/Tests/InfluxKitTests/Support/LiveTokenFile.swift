import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Reads the live test's bearer token from a private file, so a token never
/// has to pass through a shell variable. The file holds either the bare
/// token on one line, or one `NAME=value` line (the shape of a dotenv file
/// with a single entry; the value may be quoted). Blank lines and `#`
/// comments are ignored. The file must be a regular file (not a symlink),
/// owned by the user running the test, that no group or other user can
/// read or write, and it must hold exactly
/// one non-empty value. Errors never include the file's contents.
enum LiveTokenFile {
    enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable
        case notARegularFile
        case notOwned
        case tooOpen
        case tooLarge
        case empty
        case malformed

        var description: String {
            switch self {
            case .unreadable: "the token file cannot be read"
            case .notARegularFile: "the token file must be a regular file, not a link or a directory"
            case .notOwned: "the token file must belong to the user running the test"
            case .tooOpen: "the token file must not be readable or writable by group or others (chmod 600)"
            case .tooLarge: "the token file is larger than a token file should be"
            case .empty: "the token file holds no token"
            case .malformed: "the token file must hold one token, or one NAME=value line"
            }
        }
    }

    static let sizeLimit = 8192

    static func read(at path: String) throws(Failure) -> String {
        // Open first, without following a final symlink, and check what was
        // opened, so the file cannot be swapped between the check and the
        // read. Non-blocking, so a FIFO is refused rather than waited on.
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw errno == ELOOP ? .notARegularFile : .unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw .unreadable }
        guard UInt32(info.st_mode) & 0o170000 == 0o100000 else { throw .notARegularFile }
        guard info.st_uid == getuid() else { throw .notOwned }
        guard UInt32(info.st_mode) & 0o077 == 0 else { throw .tooOpen }
        guard let data = try? handle.read(upToCount: sizeLimit + 1) ?? Data() else { throw .unreadable }
        guard data.count <= sizeLimit else { throw .tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw .malformed }
        return try token(in: text)
    }

    static func token(in text: String) throws(Failure) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        guard !lines.isEmpty else { throw .empty }
        guard lines.count == 1 else { throw .malformed }
        var value = Substring(lines[0])
        if let equals = value.firstIndex(of: "=") {
            var name = value[..<equals].trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("export ") { name = String(name.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces) }
            guard isVariableName(name) else { throw .malformed }
            value = Substring(value[value.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                value = value.dropFirst().dropLast()
            }
        }
        guard !value.isEmpty else { throw .empty }
        guard !value.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "'" || $0 == "=" }) else { throw .malformed }
        return String(value)
    }

    private static func isVariableName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || ("A"..."Z").contains(first) || ("a"..."z").contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }
}
