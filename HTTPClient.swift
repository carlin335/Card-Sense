//
//  HTTPClient.swift
//  CardSense
//
//  Created by Carlin Jon Soorenian on 10/8/25.
//
import Foundation

enum HTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 45
        cfg.timeoutIntervalForResource = 60
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.requestCachePolicy = .reloadRevalidatingCacheData
        return URLSession(configuration: cfg)
    }()

    static func fetchJSON<T: Decodable>(_ url: URL, decode: T.Type = T.self) async throws -> T {
        var lastError: Error?
        for attempt in 0..<3 {
            do {
                let (data, resp) = try await session.data(from: url)
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                return try JSONDecoder().decode(T.self, from: data)
            } catch {
                lastError = error
                if attempt < 2 {
                    let delay = UInt64(300_000_000 * (1 << attempt)) // 0.3s, 0.6s
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }
        throw lastError ?? URLError(.unknown)
    }
}
