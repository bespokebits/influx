import SwiftUI
import InfluxKit

@main
struct InfluxApp: App {
    @State private var app = AppModel.launch()

    static let windowID = "timeline"

    var body: some Scene {
        WindowGroup(id: Self.windowID) {
            if AppSettings.isUnitTestHost {
                // Hosting unit tests: an empty window, with nothing running.
                Color.clear
            } else {
                RootView(app: app) { app = AppModel.launch() }
                    #if os(macOS)
                    // A link opened while a window is open goes to it, not
                    // to a new window.
                    .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                    #endif
            }
        }
        .commands {
            SourcesCommands(requests: app.sourcesRequests)
            TimelineCommands(app: app)
            ItemCommands()
            #if os(macOS)
            // The standard panel, with the build and commit in the version
            // line (an empty .version drops the panel's own "(1)").
            CommandGroup(replacing: .appInfo) {
                Button("About Influx") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [.applicationVersion: BuildInfo.versionLine, .version: ""])
                }
            }
            #endif
        }
    }
}
