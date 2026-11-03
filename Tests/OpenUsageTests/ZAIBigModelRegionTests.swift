import XCTest
@testable import OpenUsage

/// Response bodies shared with the `@Sendable` routing closures, kept off the `@MainActor` test
/// class so the closures can read them without hopping actors.
private enum ZAIBigModelFixtures {
    static let quotaBody = #"""
    {"code":200,"msg":"Operation successful","data":{"limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":17,"nextResetTime":1782724971179},
      {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":3,"nextResetTime":1783305486997}
    ],"level":"pro"},"success":true}
    """#

    static let subscriptionBody = #"""
    {"code":200,"msg":"Operation successful","data":[{"productName":"GLM Coding Pro","status":"VALID"}],"success":true}
    """#
}

/// A BigModel (China-region) key must reach `open.bigmodel.cn` with the raw key, while a Z.ai key
/// keeps going to `api.z.ai` as a Bearer token \u2014 and a key the first region refuses must be
/// retried against the other region before it is called rejected.
@MainActor
final class ZAIBigModelRegionTests: XCTestCase {
    func testBigModelRequestsUseTheRawKeyAndTheBigModelHost() async throws {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Data()) }
        let client = ZAIUsageClient(http: http)

        _ = try await client.fetchQuota(apiKey: "bigmodel-key", region: .bigModel)
        _ = try await client.fetchSubscription(apiKey: "bigmodel-key", region: .bigModel)

        XCTAssertEqual(http.requests.map(\.url.absoluteString), [
            "https://open.bigmodel.cn/api/monitor/usage/quota/limit",
            "https://open.bigmodel.cn/api/biz/subscription/list"
        ])
        XCTAssertEqual(http.requests.map { $0.headers["Authorization"] }, ["bigmodel-key", "bigmodel-key"])
    }

    func testZAiRequestsKeepTheBearerTokenAndTheZAiHost() async throws {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: Data()) }
        let client = ZAIUsageClient(http: http)

        _ = try await client.fetchQuota(apiKey: "zai-key", region: .zai)

        XCTAssertEqual(http.requests.first?.url.absoluteString, "https://api.z.ai/api/monitor/usage/quota/limit")
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer zai-key")
    }

    func testAKeyRefusedByZAiIsRetriedAgainstBigModel() async throws {
        let snapshot = try await refresh(handler: { request in
            switch request.url.host() {
            case "api.z.ai":
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            case "open.bigmodel.cn":
                let body = request.url.path().contains("subscription") ? ZAIBigModelFixtures.subscriptionBody : ZAIBigModelFixtures.quotaBody
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            default:
                throw ProviderError.invalidResponse
            }
        })

        XCTAssertEqual(snapshot.plan, "GLM Coding Pro")
        XCTAssertNotNil(snapshot.lines.first { $0.label == "Session" })
    }

    func testAKeyRefusedInsideAnOKResponseIsRetriedAgainstBigModel() async throws {
        let refused = "{\"code\":401,\"msg\":\"token expired or incorrect\",\"success\":false}"
        let snapshot = try await refresh(handler: { request in
            switch request.url.host() {
            case "api.z.ai":
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(refused.utf8))
            case "open.bigmodel.cn":
                let body = request.url.path().contains("subscription") ? ZAIBigModelFixtures.subscriptionBody : ZAIBigModelFixtures.quotaBody
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            default:
                throw ProviderError.invalidResponse
            }
        })

        XCTAssertEqual(snapshot.plan, "GLM Coding Pro")
    }

    func testAKeyRefusedByBothRegionsStaysRejected() async throws {
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
        let runtime = try makeRuntime(http: http)

        let result = await runtime.refresh()

        XCTAssertNotNil(result.failure)
        // Both regions were asked before the key was called rejected.
        XCTAssertEqual(Set(http.requests.map { $0.url.host() }), ["api.z.ai", "open.bigmodel.cn"])
    }

    private func refresh(handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) async throws -> ProviderSnapshot {
        let runtime = try makeRuntime(http: RoutingHTTPClient(handler: handler))
        return try await runtime.refresh().get()
    }

    private func makeRuntime(http: any HTTPClient) throws -> AccountProviderRuntime {
        let account = Account(kind: .zai, label: "GLM")
        let vault = InMemoryCredentialVault()
        try vault.save(.apiKey("region-key"), for: account.id)
        return AccountProviderRuntime(account: account, vault: vault, http: http)
    }
}
