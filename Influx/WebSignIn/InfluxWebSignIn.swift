// The system web sign-in sheet, in a framework of its own. Linking
// AuthenticationServices into the app made launch load about a thousand
// more system libraries (1.45 s of the simulator's launch), so the app
// embeds this framework without linking it and loads it only when the
// reader signs in. The app calls `influx_web_sign_in_start` through dlsym.
import AuthenticationServices
import os
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// How a sign-in ended, as the app's `WebSignIn` reads it.
enum Outcome: Int {
    case signedIn = 0
    case cancelled = 1
    case couldNotStart = 2
    case failed = 3
}

/// A cancel this soon after starting came from the system, not the reader:
/// macOS ends the session at once when it won't open the page, for example
/// for an https callback the app isn't associated with.
let earliestReaderCancel: Duration = .seconds(1)

private let log = Logger(subsystem: "dev.bespokebits.influx", category: "WebSignIn")

/// One running sign-in, for the app to cancel.
@objc(InfluxWebSignInHandle)
public final class SignInHandle: NSObject, @unchecked Sendable {
    private let session: ASWebAuthenticationSession

    init(session: ASWebAuthenticationSession) {
        self.session = session
    }

    /// Dismisses the sheet if it's showing. The completion doesn't run.
    @objc public func cancel() {
        Task { @MainActor in self.session.cancel() }
    }
}

/// Starts a sign-in on the main thread. `scheme` is set for a custom-scheme
/// callback, `host` and `path` for a universal link. `done` gets the URL the
/// service sent the browser back to, or an `Outcome` and maybe an error.
/// Returns nil when the sheet couldn't start, having called `done`.
@_cdecl("influx_web_sign_in_start")
public func influx_web_sign_in_start(
    _ url: NSURL, _ scheme: NSString?, _ host: NSString?, _ path: NSString?,
    _ done: @escaping @Sendable @convention(block) (NSURL?, Int, NSError?) -> Void
) -> SignInHandle? {
    // Strings and URLs are Sendable; their NS forms can't cross into the
    // main-actor closure.
    let url = url as URL, scheme = scheme as String?, host = host as String?, path = path as String?
    return MainActor.assumeIsolated {
        let callback: ASWebAuthenticationSession.Callback
        if let scheme {
            callback = .customScheme(scheme)
        } else if let host, let path {
            callback = .https(host: host, path: path)
        } else {
            done(nil, Outcome.couldNotStart.rawValue, nil)
            return nil
        }
        #if canImport(UIKit)
        // The sheet shows over one of the app's scenes; with none it can't.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else {
            log.error("Web sign-in had no scene to show in")
            done(nil, Outcome.couldNotStart.rawValue, nil)
            return nil
        }
        let anchor = PresentationAnchor(scene: scene)
        #else
        let anchor = PresentationAnchor()
        #endif
        let started = ContinuousClock.now
        // The completion holds the presentation provider, which the session
        // only holds weakly, until it runs. It must not be main-actor code:
        // on macOS it runs on Safari's XPC queue, and an inherited
        // @MainActor traps there.
        let session = ASWebAuthenticationSession(url: url, callback: callback) { @Sendable url, error in
            _ = anchor
            if let url {
                log.info("Web sign-in came back")
                done(url as NSURL, Outcome.signedIn.rawValue, nil)
                return
            }
            log.error("Web sign-in ended without a callback: \(String(describing: error), privacy: .public)")
            if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                let early = ContinuousClock.now - started < earliestReaderCancel
                done(nil, (early ? Outcome.couldNotStart : Outcome.cancelled).rawValue, nil)
            } else {
                done(nil, error == nil ? Outcome.cancelled.rawValue : Outcome.failed.rawValue, error as NSError?)
            }
        }
        session.presentationContextProvider = anchor
        // A fresh browser session each time, so signing in to a second
        // account on the same instance doesn't reuse the first one's cookies.
        session.prefersEphemeralWebBrowserSession = true
        // When the sheet can't start, the completion never runs.
        guard session.start() else {
            log.error("Web sign-in session didn't start")
            done(nil, Outcome.couldNotStart.rawValue, nil)
            return nil
        }
        log.info("Web sign-in started")
        return SignInHandle(session: session)
    }
}

/// Presents the sheet over the app's key window. Only read on the main
/// thread, so it can travel with the completion.
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    #if canImport(UIKit)
    /// The scene the sign-in started in.
    private let scene: UIWindowScene

    init(scene: UIWindowScene) {
        self.scene = scene
    }
    #endif

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // The system asks on the main thread.
        MainActor.assumeIsolated {
            #if canImport(UIKit)
            return scene.keyWindow ?? scene.windows.first ?? UIWindow(windowScene: scene)
            #else
            // An unattached window can't host the sheet, so fall back to
            // any window that's on screen.
            let app = NSApplication.shared
            guard var window = app.keyWindow ?? app.mainWindow ?? app.windows.first(where: \.isVisible) else {
                log.error("Web sign-in had no window to show in")
                return ASPresentationAnchor()
            }
            // A window that already has a sheet shows another only after
            // that one closes, so the sign-in goes on the topmost sheet
            // (an account screen's, say), or it would wait unseen.
            while let sheet = window.attachedSheet, sheet.isVisible {
                window = sheet
            }
            log.info("Web sign-in shows on a \(String(describing: type(of: window)), privacy: .public), sheet: \(window.isSheet, privacy: .public)")
            return window
            #endif
        }
    }
}
