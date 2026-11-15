// Frameworks the app embeds but doesn't link, loaded on first use, so the
// system frameworks they link stay out of launch: InfluxWebSignIn
// (AuthenticationServices) and InfluxVideo (AVFoundation, AVKit). Each
// exposes plain C entry points, found here by name.
import Darwin
import Foundation
import os

enum EmbeddedFramework {
    private static let log = Logger(subsystem: "dev.bespokebits.influx", category: "EmbeddedFramework")

    /// The address of `symbol` in `Frameworks/<name>.framework`, loading it
    /// the first time; nil, logged, if either can't be found.
    static func symbol(_ symbol: String, in name: String) -> UnsafeMutableRawPointer? {
        guard let frameworks = Bundle.main.privateFrameworksURL else { return nil }
        let binary = frameworks.appending(path: "\(name).framework/\(name)")
        // dlopen returns the same handle once loaded, so this is cheap after
        // the first call.
        guard let image = dlopen(binary.path, RTLD_NOW), let address = dlsym(image, symbol) else {
            let reason = dlerror().map { String(cString: $0) } ?? "no error"
            log.error("\(name, privacy: .public) didn't load \(symbol, privacy: .public): \(reason, privacy: .public)")
            return nil
        }
        return address
    }
}
