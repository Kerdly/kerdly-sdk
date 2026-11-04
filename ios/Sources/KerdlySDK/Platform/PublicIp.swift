import Foundation

/// The device's public IPv6 from the config's echo URL. The echo host has AAAA
/// records only, so it answers only over IPv6. One `GET` on an ephemeral session (no cookies, no URL
/// cache), 3 s in all, no retry; any failure completes with nil.
final class SystemPublicIp: PublicIpProviding {
    static let timeout: TimeInterval = 3

    func lookup(_ url: URL, completion: @escaping @Sendable (String?) -> Void) {
        guard url.scheme?.lowercased() == "https" else { return completion(nil) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request) { data, response, _ in
            guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
                return completion(nil)
            }
            completion(data.flatMap(JSONValue.parse)?["ip"]?.stringValue)
        }.resume()
        // Ends the session once the task is done.
        session.finishTasksAndInvalidate()
    }
}
