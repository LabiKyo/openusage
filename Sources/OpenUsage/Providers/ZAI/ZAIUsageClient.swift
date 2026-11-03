import Foundation

struct ZAIUsageClient: Sendable {
    /// Zhipu sells the GLM Coding Plan in two regions, and a key only works in the region that
    /// issued it: Z.ai (international) and BigModel (China). Both regions serve the same paths,
    /// but the Authorization header differs \u2014 Z.ai takes the key as a Bearer token, while
    /// BigModel takes the raw key.
    enum Region: Sendable, Equatable {
        case zai
        case bigModel

        var host: String {
            switch self {
            case .zai: "api.z.ai"
            case .bigModel: "open.bigmodel.cn"
            }
        }

        func authorizationHeader(for apiKey: String) -> String {
            switch self {
            case .zai: "Bearer \(apiKey)"
            case .bigModel: apiKey
            }
        }

        var other: Region { self == .zai ? .bigModel : .zai }
    }

    /// The Z.ai URLs, kept for callers that match requests by URL.
    static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func fetchSubscription(apiKey: String, region: Region = .zai) async throws -> HTTPResponse {
        try await get(path: "/api/biz/subscription/list", apiKey: apiKey, region: region)
    }

    func fetchQuota(apiKey: String, region: Region = .zai) async throws -> HTTPResponse {
        try await get(path: "/api/monitor/usage/quota/limit", apiKey: apiKey, region: region)
    }

    /// A region refuses a key issued elsewhere with an HTTP 401/403, or with an HTTP 200 whose
    /// body carries `code: 401` and `success: false` \u2014 the shape the mapper reads as a rejected
    /// key once the key's region is known.
    static func rejectsKey(_ response: HTTPResponse) -> Bool {
        if ProviderError.isAuthFailure(response) { return true }
        guard let root = ProviderParse.jsonObject(response.body),
              (root["success"] as? Bool) == false else { return false }
        return ProviderParse.number(root["code"]) == 401
    }

    private func get(path: String, apiKey: String, region: Region) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: URL(string: "https://\(region.host)\(path)")!,
            headers: [
                "Authorization": region.authorizationHeader(for: apiKey),
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}
