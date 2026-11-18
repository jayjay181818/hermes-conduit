import Foundation
import XCTest
@testable import Conduit

extension MacWheelSwipeGuardTests {
    func testCanonicalMacTagParsesAndUsesBuildAsTheOrderingKey() throws {
        let older = try XCTUnwrap(MacReleaseVersion.parse(tag: "macos/v2.4.1-build-278"))
        let hotfix = try XCTUnwrap(MacReleaseVersion.parse(tag: "macos/v2.3.9-build-279"))
        XCTAssertEqual(older.marketingVersion, "2.4.1")
        XCTAssertEqual(older.tag, "macos/v2.4.1-build-278")
        XCTAssertLessThan(older.build, hotfix.build)
        XCTAssertNil(MacReleaseVersion.parse(tag: "v2.4.1-build-279"))
        XCTAssertNil(MacReleaseVersion.parse(tag: "macos/v2.4-build-279"))
        XCTAssertNil(MacReleaseVersion.parse(tag: "macos/v02.4.1-build-279"))
        XCTAssertNil(MacReleaseVersion.parse(tag: "macos/v2.4.1-build-0"))
        XCTAssertNil(MacReleaseVersion.parse(tag: "macos/v2.4.1-build-279-extra"))
    }

    func testOnlyLatestPublishedCanonicalMacBuildCanBeOffered() throws {
        let latest = try MacReleaseCatalog.latestUpdate(in: [
            release(tag: "v99.0.0-build-999", published: true),
            release(tag: "macos/v9.0.0-build-900", prerelease: true, published: true),
            release(tag: "macos/v2.4.1-build-278", published: true),
            release(tag: "macos/v2.4.2-build-280", published: true),
            release(tag: "macos/v2.4.1-build-279", published: true)
        ], currentBuild: 278)
        XCTAssertEqual(latest?.version.build, 280)
        XCTAssertEqual(latest?.version.marketingVersion, "2.4.2")
        XCTAssertEqual(latest?.assetID, 280)
        XCTAssertEqual(latest?.sha256, String(repeating: "a", count: 64))
    }

    func testNoPublishedMacReleaseFailsClosedAndCurrentOrNewerBuildIsNotOffered() throws {
        XCTAssertThrowsError(try MacReleaseCatalog.latestUpdate(in: [], currentBuild: 1)) {
            XCTAssertEqual($0 as? MacUpdaterError, .noPublishedRelease)
        }
        XCTAssertNil(try MacReleaseCatalog.latestUpdate(in: [release(tag: "macos/v2.4.1-build-278", published: true)], currentBuild: 278))
        XCTAssertNil(try MacReleaseCatalog.latestUpdate(in: [release(tag: "macos/v2.3.0-build-277", published: true)], currentBuild: 278))
    }

    func testUnpublishedPrereleaseAndDraftMacReleaseAreIgnored() throws {
        XCTAssertThrowsError(try MacReleaseCatalog.latestUpdate(in: [
            release(tag: "macos/v2.4.1-build-278", published: false),
            release(tag: "macos/v2.4.1-build-279", draft: true, published: false),
            release(tag: "macos/v2.4.1-build-280", prerelease: true, published: false)
        ], currentBuild: 1)) {
            XCTAssertEqual($0 as? MacUpdaterError, .noPublishedRelease)
        }
    }

    func testInvalidMacTagOrDuplicateNewestBuildFailsClosed() {
        XCTAssertThrowsError(try MacReleaseCatalog.latestUpdate(in: [release(tag: "macos/current", published: true)], currentBuild: 1))
        XCTAssertThrowsError(try MacReleaseCatalog.latestUpdate(in: [
            release(tag: "macos/v2.4.1-build-278", published: true),
            release(tag: "macos/v2.4.2-build-278", published: true)
        ], currentBuild: 1))
    }

    func testPackageMustBeUniqueDigestBoundAndHostedAtExactRepositoryAssetEndpoint() {
        var item = release(tag: "macos/v2.4.1-build-278", published: true)
        item = replacingAssets(item, [asset(url: "https://api.github.com/repos/other/repo/releases/assets/278")])
        XCTAssertThrowsError(try MacReleaseCatalog.latestUpdate(in: [item], currentBuild: 1))

        item = replacingAssets(item, [asset(digest: nil)])
        XCTAssertThrowsError(try MacReleaseCatalog.latestUpdate(in: [item], currentBuild: 1))

        item = replacingAssets(item, [asset(digest: "sha256:ABC")])
        XCTAssertThrowsError(try MacReleaseCatalog.latestUpdate(in: [item], currentBuild: 1))

        item = replacingAssets(item, [asset(), asset(id: 281)])
        XCTAssertThrowsError(try MacReleaseCatalog.latestUpdate(in: [item], currentBuild: 1))

        item = replacingAssets(item, [asset(size: MacReleaseCatalog.maximumAssetSize + 1)])
        XCTAssertThrowsError(try MacReleaseCatalog.latestUpdate(in: [item], currentBuild: 1))
    }

    func testFixedRepositoryURLsAndRestrictiveCDNRedirects() {
        XCTAssertEqual(MacReleaseCatalog.releaseListURL().absoluteString,
                       "https://api.github.com/repos/jayjay181818/hermes-conduit/releases?per_page=100")
        XCTAssertTrue(MacReleaseCatalog.isAssetEndpoint(URL(string: "https://api.github.com/repos/jayjay181818/hermes-conduit/releases/assets/278")!, assetID: 278))
        XCTAssertFalse(MacReleaseCatalog.isAssetEndpoint(URL(string: "https://api.github.com/repos/other/repo/releases/assets/278")!, assetID: 278))
        XCTAssertFalse(MacReleaseCatalog.isAssetEndpoint(URL(string: "https://api.github.com/repos/jayjay181818/hermes-conduit/releases/assets/278?download=1")!, assetID: 278))
        XCTAssertTrue(MacReleaseCatalog.isAssetRedirect(URL(string: "https://release-assets.githubusercontent.com/path?token=opaque")!))
        XCTAssertFalse(MacReleaseCatalog.isAssetRedirect(URL(string: "https://githubusercontent.com/path")!))
        XCTAssertFalse(MacReleaseCatalog.isAssetRedirect(URL(string: "http://release-assets.githubusercontent.com/path")!))
        XCTAssertFalse(MacReleaseCatalog.isAssetRedirect(URL(string: "https://release-assets.githubusercontent.com.evil.example/path")!))
    }

    func testPaginationRequiresNextPageOnExactRepositoryEndpoint() throws {
        XCTAssertEqual(try MacReleaseCatalog.nextPage(
            from: "<https://api.github.com/repos/jayjay181818/hermes-conduit/releases?per_page=100&page=2>; rel=\"next\"", currentPage: 1), 2)
        XCTAssertNil(try MacReleaseCatalog.nextPage(from: nil, currentPage: 1))
        XCTAssertThrowsError(try MacReleaseCatalog.nextPage(
            from: "<https://api.github.com/repos/other/repo/releases?per_page=100&page=2>; rel=\"next\"", currentPage: 1))
        XCTAssertThrowsError(try MacReleaseCatalog.nextPage(
            from: "<https://evil.example/repos/jayjay181818/hermes-conduit/releases?per_page=100&page=2>; rel=\"next\"", currentPage: 1))
    }

#if targetEnvironment(macCatalyst)
    func testProductionDownloadUsesFixedEndpointAndFileSHAWithNoAmbientHeaders() async throws {
        let body = Data("public deterministic package fixture".utf8)
        let digest = "a695f58dc751cdb6332a7048f8ff876facf2df3c4f61453e7ea9e3ff5f62ab64"
        let endpoint = assetEndpoint()
        UpdaterTransportFixture.install { _ in
            .body(status: 200, body: body, headers: ["Content-Length": String(body.count)])
        }
        defer { UpdaterTransportFixture.reset() }

        let configuration = fixtureConfiguration()
        configuration.httpAdditionalHeaders = [
            "Cookie": "fixture-cookie=must-not-send",
            "Authorization": "fixture-authorization=must-not-send",
            "X-Dashboard-Authorization": "fixture-dashboard=must-not-send",
            "X-API-Key": "fixture-key=must-not-send"
        ]
        configuration.httpShouldSetCookies = true

        let package = try await MacPackageDownloader.download(
            descriptor(endpoint: endpoint, size: body.count, digest: digest),
            configuration: configuration
        )
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }

        XCTAssertEqual(package.lastPathComponent, MacReleaseCatalog.packageName)
        XCTAssertEqual(try MacReleaseDigest.sha256(fileAt: package), digest)
        let requests = UpdaterTransportFixture.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url, endpoint)
        XCTAssertEqual(request.httpMethod, "GET")
        let headers = Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(headers["accept"], "application/octet-stream")
        XCTAssertEqual(headers["user-agent"], "Hermes-Conduit-Mac-Updater")
        for forbidden in ["cookie", "authorization", "x-dashboard-authorization", "x-api-key"] {
            XCTAssertNil(headers[forbidden], "Updater leaked \(forbidden) into the GitHub asset request")
        }
    }

    func testProductionDownloadRejectsDigestMismatchAndHTTPFailure() async throws {
        defer { UpdaterTransportFixture.reset() }
        let body = Data("public deterministic package fixture".utf8)
        let endpoint = assetEndpoint()
        UpdaterTransportFixture.install { _ in
            .body(status: 200, body: body, headers: ["Content-Length": String(body.count)])
        }
        let configuration = fixtureConfiguration()
        do {
            _ = try await MacPackageDownloader.download(
                descriptor(endpoint: endpoint, size: body.count, digest: String(repeating: "0", count: 64)),
                configuration: configuration
            )
            XCTFail("A package with the wrong GitHub digest must be discarded")
        } catch let error as MacUpdaterError {
            XCTAssertEqual(error, .digestMismatch)
        }

        do {
            _ = try await MacPackageDownloader.download(
                descriptor(endpoint: endpoint, size: body.count + 1, digest: String(repeating: "0", count: 64)),
                configuration: fixtureConfiguration()
            )
            XCTFail("A package shorter than its advertised size must be discarded")
        } catch let error as MacUpdaterError {
            XCTAssertEqual(error, .invalidAsset("download size did not match release metadata"))
        }

        UpdaterTransportFixture.install { _ in .body(status: 404, body: Data(), headers: [:]) }
        do {
            _ = try await MacPackageDownloader.download(
                descriptor(endpoint: endpoint, size: 1, digest: String(repeating: "0", count: 64)),
                configuration: fixtureConfiguration()
            )
            XCTFail("An unavailable asset must fail closed")
        } catch let error as MacUpdaterError {
            XCTAssertEqual(error, .httpStatus(404))
        }
    }

    func testProductionDownloadCapsUnknownLengthResponse() async throws {
        let endpoint = assetEndpoint()
        UpdaterTransportFixture.install { _ in
            .body(status: 200, body: Data(repeating: 0x41, count: 64), headers: [:])
        }
        defer { UpdaterTransportFixture.reset() }

        do {
            _ = try await MacPackageDownloader.download(
                descriptor(endpoint: endpoint, size: 8, digest: String(repeating: "a", count: 64)),
                configuration: fixtureConfiguration(),
                maximumSize: 8
            )
            XCTFail("A chunked response exceeding the size limit must be cancelled")
        } catch let error as MacUpdaterError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testProductionDownloadAllowsOnlyTheFixedGitHubAssetCDNRedirect() async throws {
        let endpoint = assetEndpoint()
        let cdn = URL(string: "https://release-assets.githubusercontent.com/fixture/asset")!
        let body = Data("public deterministic package fixture".utf8)
        let digest = "a695f58dc751cdb6332a7048f8ff876facf2df3c4f61453e7ea9e3ff5f62ab64"
        let configuration = fixtureConfiguration()
        configuration.httpAdditionalHeaders = [
            "Cookie": "fixture-cookie=must-not-send",
            "Authorization": "fixture-authorization=must-not-send",
            "X-Dashboard-Authorization": "fixture-dashboard=must-not-send",
            "X-API-Key": "fixture-key=must-not-send"
        ]
        configuration.httpShouldSetCookies = true
        UpdaterTransportFixture.install { request in
            if request.url == endpoint { return .redirect(to: cdn) }
            return .body(status: 200, body: body, headers: ["Content-Length": String(body.count)])
        }
        defer { UpdaterTransportFixture.reset() }

        let package = try await MacPackageDownloader.download(
            descriptor(endpoint: endpoint, size: body.count, digest: digest),
            configuration: configuration
        )
        defer { try? FileManager.default.removeItem(at: package.deletingLastPathComponent()) }
        XCTAssertEqual(try MacReleaseDigest.sha256(fileAt: package), digest)
        let requests = UpdaterTransportFixture.requests
        XCTAssertEqual(requests.compactMap(\.url), [endpoint, cdn])
        for request in requests {
            let headers = Dictionary((request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
            for forbidden in ["cookie", "authorization", "x-dashboard-authorization", "x-api-key"] {
                XCTAssertNil(headers[forbidden], "Updater leaked \(forbidden) to \(request.url?.host ?? "unknown host")")
            }
        }

        let hostile = URL(string: "https://downloads.example.invalid/fixture/asset")!
        UpdaterTransportFixture.install { request in
            if request.url == endpoint { return .redirect(to: hostile) }
            return .body(status: 200, body: body, headers: ["Content-Length": String(body.count)])
        }
        do {
            _ = try await MacPackageDownloader.download(
                descriptor(endpoint: endpoint, size: body.count, digest: digest),
                configuration: fixtureConfiguration()
            )
            XCTFail("Redirects away from GitHub's asset CDN must be rejected")
        } catch let error as MacUpdaterError {
            XCTAssertEqual(error, .invalidAsset("GitHub redirected the package to an unapproved host"))
        }
    }
#endif

    private func release(tag: String, draft: Bool = false, prerelease: Bool = false, published: Bool) -> GitHubMacRelease {
        GitHubMacRelease(tagName: tag, draft: draft, prerelease: prerelease,
                         publishedAt: published ? "2026-11-18T09:00:00Z" : nil,
                         assets: [asset(id: Int(MacReleaseVersion.parse(tag: tag)?.build ?? 1))])
    }

    private func asset(id: Int = 278, size: Int = 1024, digest: String? = "sha256:" + String(repeating: "a", count: 64),
                       url: String? = nil) -> GitHubMacRelease.Asset {
        GitHubMacRelease.Asset(id: id, name: MacReleaseCatalog.packageName, size: size,
                               url: url ?? "https://api.github.com/repos/jayjay181818/hermes-conduit/releases/assets/\(id)", digest: digest)
    }

    private func replacingAssets(_ release: GitHubMacRelease, _ assets: [GitHubMacRelease.Asset]) -> GitHubMacRelease {
        GitHubMacRelease(tagName: release.tagName, draft: release.draft, prerelease: release.prerelease,
                         publishedAt: release.publishedAt, assets: assets)
    }

#if targetEnvironment(macCatalyst)
    private func assetEndpoint() -> URL {
        URL(string: "https://api.github.com/repos/jayjay181818/hermes-conduit/releases/assets/278")!
    }

    private func descriptor(endpoint: URL, size: Int, digest: String) -> MacReleaseDescriptor {
        MacReleaseDescriptor(
            version: MacReleaseVersion(major: 2, minor: 4, patch: 1, build: 279),
            assetID: 278,
            assetSize: size,
            assetURL: endpoint,
            sha256: digest
        )
    }

    private func fixtureConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdaterTransportFixture.self]
        return configuration
    }
#endif
}

#if targetEnvironment(macCatalyst)
private final class UpdaterTransportFixture: URLProtocol {
    enum Reply {
        case body(status: Int, body: Data, headers: [String: String])
        case redirect(to: URL)
    }

    private static let lock = NSLock()
    private static var responder: ((URLRequest) -> Reply)?
    private static var capturedRequests: [URLRequest] = []

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    static func install(_ responder: @escaping (URLRequest) -> Reply) {
        lock.lock()
        self.responder = responder
        capturedRequests = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        responder = nil
        capturedRequests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.capturedRequests.append(request)
        let responder = Self.responder
        Self.lock.unlock()

        guard let responder else {
            client?.urlProtocol(self, didFailWithError: MacUpdaterError.downloadFailed("fixture was not configured"))
            return
        }
        switch responder(request) {
        case .body(let status, let body, let headers):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: MacUpdaterError.downloadFailed("fixture response could not be formed"))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let destination):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString]) else {
                client?.urlProtocol(self, didFailWithError: MacUpdaterError.downloadFailed("fixture redirect could not be formed"))
                return
            }
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
        }
    }

    override func stopLoading() { }
}
#endif
