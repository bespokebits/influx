import Foundation
#if canImport(os)
import os
#endif

/// Why a service refused to renew a sign-in, in the log under the
/// "Accounts" category, so the next sign-out has a cause on record
/// (`log show --predicate 'category == "Accounts"'`).
public enum AuthLog {
    #if canImport(os)
    private static let log = Logger(subsystem: "dev.bespokebits.influx", category: "Accounts")
    #endif

    /// A token endpoint's refusal: the service, the HTTP status, and the
    /// OAuth `error` and `error_description` it sent, if any.
    static func refused(_ service: String, account: String, status: Int, data: Data) {
        struct Body: Decodable {
            var error: String?
            var error_description: String?
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let error = body?.error ?? "none"
        let description = body?.error_description ?? "none"
        #if canImport(os)
        log.error("\(service, privacy: .public) refresh refused: HTTP \(status, privacy: .public) error=\(error, privacy: .public) description=\(description, privacy: .public) account=\(account, privacy: .private(mask: .hash))")
        #endif
    }

    /// A request a service refused although its token was fresh, which
    /// isn't counted as a sign-out.
    static func rejected(_ service: String, status: Int, error: String) {
        #if canImport(os)
        log.error("\(service, privacy: .public) request refused: HTTP \(status, privacy: .public) error=\(error, privacy: .public)")
        #endif
    }

    /// Why a request to the signing service went without App Attest
    /// (ADR 0033): the platform or the Worker couldn't attest this install.
    static func cannotAttest(_ reason: String) {
        #if canImport(os)
        log.error("App Attest unavailable, asking unattested: \(reason, privacy: .public)")
        #endif
    }

    /// A keychain read that failed, so the account keeps its last known
    /// sign-in state.
    public static func unreadable(account: String, error: any Error) {
        #if canImport(os)
        log.error("credentials unreadable: \(String(describing: error), privacy: .public) account=\(account, privacy: .private(mask: .hash))")
        #endif
    }
}
