import Foundation

/// Requests to this Mac (the sibling apps, a local model server, Flimmer for a send, a test's server) go through a
/// session with no cache at all (the series' lesson, COMFORT.md 620092e, from Flimmer): URLSession's shared cache keeps
/// a 301 or a 308 for good, also for 127.0.0.1, and sent a test to a port nothing listened on any more. Something on
/// this Mac comes and goes, and changes port; an answer about it is true only when it is given.
public enum LocalSession {
    public static let shared: URLSession = URLSession(configuration: configuration)

    /// Ephemeral (nothing on disk), no URLCache, and every request asked anew.
    public static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return c
    }

    /// Whether `url` is on this Mac.
    public static func isThisMac(_ url: URL?) -> Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }

    /// The local session for an address on this Mac, `otherwise` for one elsewhere.
    public static func session(for url: URL?, otherwise: URLSession = .shared) -> URLSession {
        isThisMac(url) ? shared : otherwise
    }
}
