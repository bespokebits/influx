import Foundation

/// Sources that have kept failing for more than a day, for the notice that
/// names them. A quiet problem state is easy to miss; one
/// that lasts this long needs the reader to look.
public enum FailingSources {
    /// How long a problem must last, by the source's own fetch attempts,
    /// before it is raised.
    public static let threshold: TimeInterval = 24 * 60 * 60

    /// The IDs of the sources in `states` whose current problem has lasted
    /// past `threshold`, oldest problem first. The source must have been
    /// tried and still failed a day after the problem started, so a device
    /// that was closed for a day raises nothing until it has tried again.
    /// A source that couldn't be reached only counts while another source
    /// that fetched fine since then can still be reached, since otherwise
    /// it is the device that is offline, not the source.
    public static func ids(in states: [SourceFetchState]) -> [String] {
        states.compactMap { state -> (Date, String)? in
            guard let problem = state.problem, let since = state.problemSince, let tried = state.lastAttemptAt else { return nil }
            let raisedAt = since.addingTimeInterval(threshold)
            guard tried >= raisedAt else { return nil }
            if problem == .offline {
                let deviceWasOnline = states.contains { other in
                    other.sourceID != state.sourceID && other.problem != .offline
                        && (other.lastSuccessAt.map { $0 >= raisedAt } ?? false)
                }
                guard deviceWasOnline else { return nil }
            }
            return (since, state.sourceID)
        }
        .sorted { $0 < $1 }
        .map(\.1)
    }
}
