import Foundation

/// Every request that carries a key goes out through here. URLSession follows redirects by itself and
/// takes the request's headers along, so a provider (or something in front of it) answering "go to this
/// other host" would have the key sent there. Here a redirect to another host, to another port, or down
/// from https is not followed: the redirect is the answer, and the caller reports it as the provider's
/// status ("Berget answered HTTP 302").
///
/// A key also never follows an address that came in a provider's answer (a status or result link):
/// `sameOrigin` is the check to make before such an address is asked with the key. Nothing in Jämmer
/// does that today.
public enum KeyedRequest {
    public static func sameOrigin(_ a: URL?, _ b: URL?) -> Bool {
        guard let a, let b, let ha = a.host?.lowercased(), let hb = b.host?.lowercased(), ha == hb else { return false }
        func port(_ u: URL) -> Int { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : 80) }
        return a.scheme?.lowercased() == b.scheme?.lowercased() && port(a) == port(b)
    }

    final class Delegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(KeyedRequest.sameOrigin(task.originalRequest?.url, request.url) ? request : nil)
        }
    }

    public static func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        try await session.data(for: request, delegate: Delegate())
    }

    public static func webSocket(for request: URLRequest, session: URLSession) -> URLSessionWebSocketTask {
        let task = session.webSocketTask(with: request)
        task.delegate = Delegate()
        return task
    }
}
