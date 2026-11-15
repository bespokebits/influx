import Foundation

/// Which build this is, for the version line on the Sources screen and the
/// Mac's About panel. `InfluxCommit` is the commit the build was made from;
/// a build script sets it (Configs/BuildCommit.local.xcconfig), and builds
/// from Xcode leave it empty.
enum BuildInfo {
    /// "0.1.0 (1) · 5e8404a", or "0.1.0 (1)" without a commit.
    static func versionLine(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        var line = version
        if let build = info["CFBundleVersion"] as? String, !build.isEmpty {
            line += " (\(build))"
        }
        if let commit = info["InfluxCommit"] as? String, !commit.isEmpty {
            line += " · \(commit)"
        }
        return line
    }

    static var versionLine: String { versionLine(info: Bundle.main.infoDictionary ?? [:]) }
}
