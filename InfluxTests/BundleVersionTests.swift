// What App Store Connect checks in the app's bundles before TestFlight
// takes a build.
import Foundation
import Testing

/// Every framework the app carries has the app's version. App Store Connect
/// refuses a build with a framework that has no CFBundleShortVersionString
/// (error 90057), which only an upload would otherwise show.
@Test func everyEmbeddedFrameworkHasTheAppsVersion() throws {
    let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
    let folder = try #require(Bundle.main.privateFrameworksURL)
    let frameworks = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "framework" }
    #expect(frameworks.map { $0.deletingPathExtension().lastPathComponent }.sorted()
        == ["InfluxMetrics", "InfluxSync", "InfluxVideo", "InfluxWebSignIn"])
    for url in frameworks {
        let bundle = try #require(Bundle(url: url))
        #expect(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
                "\(url.lastPathComponent)")
    }
}
