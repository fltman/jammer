import Foundation

/// Asking one port whether a sibling is there (SIBLINGS da5b9d2, from Flimmer, 2026-11-26): three cases told apart.
/// The connection refused: nobody listens, "not running" at once. The time up after the connection was taken: the
/// sibling is there but busy (a Jämmer that was building counted as closed), so one more try with 3 s before "not
/// running". The port answers as another app: no second try (the caller reads the answer). Tests against a pretend
/// sibling give their own, longer limits and a port outside the siblings' ranges.
public enum SiblingProbe {
    /// What a busy sibling gets on its second try.
    public static let busyRetry: TimeInterval = 3

    /// `GET <base>/api/v1/status` with `timeout`, and once more with `busyRetry` if the time ran out after the
    /// connection was taken. The status JSON as it came (a 200 with a JSON object), or nil: nobody there.
    /// `fetch` is the request as the caller makes it (URLSession, a test's pretend sibling).
    public static func status(at base: URL, timeout: TimeInterval, header: (String, String)? = nil,
                              fetch: (URLRequest) async throws -> (Data, HTTPURLResponse)) async -> [String: Any]? {
        enum Once { case answered([String: Any]?), busy }
        func once(_ t: TimeInterval) async -> Once {
            var r = URLRequest(url: base.appending(path: "api/v1/status"), timeoutInterval: t)
            if let header { r.setValue(header.1, forHTTPHeaderField: header.0) }
            do {
                let (data, response) = try await fetch(r)
                guard response.statusCode == 200 else { return .answered(nil) }
                return .answered((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
            } catch let e as URLError where e.code == .timedOut {
                return .busy
            } catch {
                // Refused, or anything else: nobody to wait for.
                return .answered(nil)
            }
        }
        switch await once(timeout) {
        case .answered(let s): return s
        case .busy:
            if case .answered(let s) = await once(max(busyRetry, timeout)) { return s }
            return nil
        }
    }
}
