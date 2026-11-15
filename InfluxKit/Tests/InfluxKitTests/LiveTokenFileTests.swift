import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif
import Testing

/// The live test's token-file reader, against temporary files holding made-up
/// values only.
struct LiveTokenFileTests {
    static let fake = "fake_token_0123456789abcdefABCDEF-_"

    /// A fresh private directory with one file in it, removed afterwards.
    private func withFile(_ contents: String?, mode: Int = 0o600, _ body: (String) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LiveTokenFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("token")
        if let contents {
            try Data(contents.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path)
        }
        try body(file.path)
    }

    @Test(arguments: [
        fake,
        "\(fake)\n",
        "  \(fake)  \n\n",
        "SAMMY_FEEDS_API_TOKEN=\(fake)\n",
        "# a comment\nSAMMY_FEEDS_API_TOKEN=\(fake)\n",
        "SOME_TOKEN = \"\(fake)\"\n",
        "export SOME_TOKEN='\(fake)'\n",
    ])
    func aPrivateFileYieldsItsTrimmedToken(contents: String) throws {
        try withFile(contents) { path in
            let token = try LiveTokenFile.read(at: path)
            #expect(token == Self.fake)
        }
    }

    @Test func aMissingFileIsRefused() throws {
        try withFile(nil) { path in
            #expect(throws: LiveTokenFile.Failure.unreadable) { try LiveTokenFile.read(at: path) }
        }
    }

    @Test(arguments: ["", "\n\n", "   \n", "# only a comment\n", "SAMMY_FEEDS_API_TOKEN=\n", "SAMMY_FEEDS_API_TOKEN=\"\"\n"])
    func anEmptyFileIsRefused(contents: String) throws {
        try withFile(contents) { path in
            #expect(throws: LiveTokenFile.Failure.empty) { try LiveTokenFile.read(at: path) }
        }
    }

    @Test(arguments: [0o644, 0o640, 0o604, 0o660, 0o606, 0o666])
    func aFileOthersCanOpenIsRefused(mode: Int) throws {
        try withFile(Self.fake, mode: mode) { path in
            #expect(throws: LiveTokenFile.Failure.tooOpen) { try LiveTokenFile.read(at: path) }
        }
    }

    @Test func aStricterModeIsAccepted() throws {
        try withFile(Self.fake, mode: 0o400) { path in
            let token = try LiveTokenFile.read(at: path)
            #expect(token == Self.fake)
        }
    }

    @Test func aLinkIsRefusedEvenToAPrivateFile() throws {
        try withFile(Self.fake) { path in
            let link = path + "-link"
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: path)
            #expect(throws: LiveTokenFile.Failure.notARegularFile) { try LiveTokenFile.read(at: link) }
        }
    }

    @Test func aFIFOIsRefusedWithoutWaiting() throws {
        try withFile(nil) { path in
            #expect(mkfifo(path, 0o600) == 0)
            #expect(throws: LiveTokenFile.Failure.notARegularFile) { try LiveTokenFile.read(at: path) }
        }
    }

    @Test func aDirectoryIsRefused() throws {
        try withFile(nil) { path in
            #expect(throws: LiveTokenFile.Failure.notARegularFile) {
                try LiveTokenFile.read(at: URL(fileURLWithPath: path).deletingLastPathComponent().path)
            }
        }
    }

    @Test(arguments: [
        "\(fake)\n\(fake)\n",
        "A=\(fake)\nB=\(fake)\n",
        "two words\n",
        "1BAD=\(fake)\n",
        "=\(fake)\n",
        "A=\"\(fake)\n",
        "A=b=c\n",
    ])
    func anythingButOneValueIsRefused(contents: String) throws {
        try withFile(contents) { path in
            #expect(throws: LiveTokenFile.Failure.malformed) { try LiveTokenFile.read(at: path) }
        }
    }

    @Test func anOversizedFileIsRefused() throws {
        try withFile(String(repeating: "a", count: LiveTokenFile.sizeLimit + 1)) { path in
            #expect(throws: LiveTokenFile.Failure.tooLarge) { try LiveTokenFile.read(at: path) }
        }
    }
}
