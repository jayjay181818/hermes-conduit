//
//  DashboardRequestAuthorizerTests+FileBackend.swift
//  Conduit
//
//  The Mac build's KeychainHelper backend (KeychainFileBackend.swift), where
//  a dashboard's cookies and tokens are kept there: the same answers the
//  system keychain gives KeychainHelper's queries, kept in one owner-only
//  file. Written as an extension of an existing suite: the CI test planner
//  finds classes in the sources, and this one exists only in the Mac build.
//

#if targetEnvironment(macCatalyst)
import Foundation
import Darwin
import Security
import XCTest
@testable import Conduit

extension DashboardRequestAuthorizerTests {
    /// A credentials file in a folder of its own under the sandbox's
    /// Application Support, matching the real store's backup domain. The
    /// system temporary directory has different backup policy on macOS.
    private func credentialsURL() -> URL {
        let support = KeychainHelper.FileBackend.defaultURL.deletingLastPathComponent().deletingLastPathComponent()
        let directory = support.appendingPathComponent("FileBackendTests-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("Credentials").appendingPathComponent("credentials.plist")
    }

    /// Read the persisted macOS exclusion, not Foundation's cached or
    /// platform-dependent Boolean. On the hosted Mac that Boolean is
    /// false even when Foundation wrote the Time Machine marker.
    private func backupExclusionMarker(_ url: URL) throws -> String? {
        try url.path.withCString { path in
            try "com.apple.metadata:com_apple_backup_excludeItem".withCString { name in
                // Capture the small marker in a single syscall. A separate
                // size query can observe a different metadata generation.
                var buffer = [UInt8](repeating: 0, count: 1024)
                let copied = buffer.withUnsafeMutableBytes {
                    getxattr(path, name, $0.baseAddress, $0.count, 0, 0)
                }
                if copied < 0 {
                    if errno == ENOATTR { return nil }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let data = Data(buffer.prefix(copied))
                return try PropertyListSerialization.propertyList(from: data, format: nil) as? String
            }
        }
    }

    private func scoped(_ account: String, service: String = "com.milim.conduit") -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func legacy(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
    }

    private func adding(_ data: Data, to query: [String: Any]) -> [String: Any] {
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return insert
    }

    func testFileBackendAddReadUpdateDeleteRoundTrip() {
        let url = credentialsURL()
        let backend = KeychainHelper.FileBackend(url: url)
        XCTAssertNil(backend.data(for: scoped("a")))
        XCTAssertEqual(backend.update(Data("x".utf8), for: scoped("a")), errSecItemNotFound)
        XCTAssertEqual(backend.add(adding(Data("one".utf8), to: scoped("a"))), errSecSuccess)
        XCTAssertEqual(backend.add(adding(Data("two".utf8), to: scoped("a"))), errSecDuplicateItem)
        XCTAssertEqual(backend.data(for: scoped("a")), Data("one".utf8))
        XCTAssertEqual(backend.update(Data("two".utf8), for: scoped("a")), errSecSuccess)
        XCTAssertEqual(backend.data(for: scoped("a")), Data("two".utf8))
        backend.delete(scoped("a"))
        XCTAssertNil(backend.data(for: scoped("a")))
    }

    func testFileBackendLegacyQueryMatchesTheAccountWhateverItsService() {
        let url = credentialsURL()
        let backend = KeychainHelper.FileBackend(url: url)
        XCTAssertEqual(backend.add(adding(Data("v".utf8), to: scoped("a"))), errSecSuccess)
        XCTAssertEqual(backend.add(adding(Data("w".utf8), to: scoped("b", service: "other"))), errSecSuccess)
        XCTAssertEqual(backend.data(for: legacy("a")), Data("v".utf8))
        XCTAssertEqual(backend.data(for: legacy("b")), Data("w".utf8))
        // A scoped query names its service: another service's record isn't it.
        XCTAssertNil(backend.data(for: scoped("b")))
        backend.delete(legacy("b"))
        XCTAssertNil(backend.data(for: scoped("b", service: "other")))
        XCTAssertEqual(backend.data(for: scoped("a")), Data("v".utf8))
    }

    func testFileBackendAccessibilityChangesOnlyAnExistingRecord() {
        let url = credentialsURL()
        let backend = KeychainHelper.FileBackend(url: url)
        XCTAssertEqual(backend.setAccessibility(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, for: scoped("a")), errSecItemNotFound)
        XCTAssertEqual(backend.add(adding(Data("v".utf8), to: scoped("a"))), errSecSuccess)
        XCTAssertEqual(backend.setAccessibility(kSecAttrAccessibleWhenUnlockedThisDeviceOnly, for: scoped("a")), errSecSuccess)
        XCTAssertEqual(backend.data(for: scoped("a")), Data("v".utf8))
    }

    func testFileBackendRecordsOutliveTheBackendThatWroteThem() {
        let url = credentialsURL()
        XCTAssertEqual(KeychainHelper.FileBackend(url: url).add(adding(Data("kept".utf8), to: scoped("a"))), errSecSuccess)
        XCTAssertEqual(KeychainHelper.FileBackend(url: url).data(for: scoped("a")), Data("kept".utf8))
    }

    func testFileBackendFileIsOwnerOnlyAndOutOfBackups() throws {
        let url = credentialsURL()
        let backend = KeychainHelper.FileBackend(url: url)
        XCTAssertEqual(backend.add(adding(Data("v".utf8), to: scoped("a"))), errSecSuccess)
        let fileMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(fileMode.intValue & 0o777, 0o600)
        let folder = url.deletingLastPathComponent()
        let folderMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(folderMode.intValue & 0o777, 0o700)
        // Check the exact sticky Time Machine marker Foundation persists.
        XCTAssertEqual(try backupExclusionMarker(folder), "com.apple.backupd")
    }

    func testFileBackendReappliesBackupExclusionToAnExistingFolder() throws {
        let url = credentialsURL()
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (folder as NSURL).setResourceValue(false, forKey: .isExcludedFromBackupKey)
        XCTAssertNil(try backupExclusionMarker(folder))
        let backend = KeychainHelper.FileBackend(url: url)
        XCTAssertEqual(backend.add(adding(Data("one".utf8), to: scoped("a"))), errSecSuccess)
        XCTAssertEqual(try backupExclusionMarker(folder), "com.apple.backupd")

        // A restore or another writer may remove the flag between saves.
        try (folder as NSURL).setResourceValue(false, forKey: .isExcludedFromBackupKey)
        XCTAssertNil(try backupExclusionMarker(folder))
        XCTAssertEqual(backend.update(Data("two".utf8), for: scoped("a")), errSecSuccess)
        XCTAssertEqual(try backupExclusionMarker(folder), "com.apple.backupd")
        XCTAssertEqual(backend.data(for: scoped("a")), Data("two".utf8))
    }

    func testFileBackendUnreadableFileReadsAsEmptyAndIsReplacedOnSave() throws {
        let url = credentialsURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a property list".utf8).write(to: url)
        let backend = KeychainHelper.FileBackend(url: url)
        XCTAssertNil(backend.data(for: scoped("a")))
        XCTAssertEqual(backend.add(adding(Data("v".utf8), to: scoped("a"))), errSecSuccess)
        XCTAssertEqual(KeychainHelper.FileBackend(url: url).data(for: scoped("a")), Data("v".utf8))
    }

    func testFileBackendUnreadableFileIsSetAsideNotOverwritten() throws {
        let url = credentialsURL()
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let damaged = Data("not a property list".utf8)
        try damaged.write(to: url)
        let backend = KeychainHelper.FileBackend(url: url)
        XCTAssertNil(backend.data(for: scoped("a")))
        XCTAssertEqual(backend.add(adding(Data("v".utf8), to: scoped("a"))), errSecSuccess)
        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("credentials.unreadable-") && $0.hasSuffix(".plist") }
        XCTAssertEqual(aside.count, 1, "the damaged file is kept beside the new one")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(try XCTUnwrap(aside.first))), damaged)
    }

    func testFileBackendAnotherCopysWriteIsReadAgainNotOverwritten() {
        // Two copies of Conduit for Mac share the file.
        let url = credentialsURL()
        let first = KeychainHelper.FileBackend(url: url)
        let second = KeychainHelper.FileBackend(url: url)
        XCTAssertEqual(first.add(adding(Data("a".utf8), to: scoped("a"))), errSecSuccess)
        XCTAssertEqual(second.data(for: scoped("a")), Data("a".utf8))
        XCTAssertEqual(second.add(adding(Data("b".utf8), to: scoped("b"))), errSecSuccess)
        XCTAssertEqual(first.data(for: scoped("b")), Data("b".utf8))
        XCTAssertEqual(first.add(adding(Data("c".utf8), to: scoped("c"))), errSecSuccess)
        let fresh = KeychainHelper.FileBackend(url: url)
        XCTAssertEqual(fresh.data(for: scoped("a")), Data("a".utf8))
        XCTAssertEqual(fresh.data(for: scoped("b")), Data("b".utf8))
        XCTAssertEqual(fresh.data(for: scoped("c")), Data("c".utf8))
    }

    func testKeychainHelperSavesAndClearsThroughTheFileBackend() {
        let url = credentialsURL()
        KeychainHelper.useBackendForTesting(KeychainHelper.FileBackend(url: url))
        let dashboard = UUID()
        let tokens = Data("tokens".utf8)
        KeychainHelper.saveDashboardCookies(tokens, dashboardID: dashboard)
        XCTAssertEqual(KeychainHelper.loadDashboardCookies(dashboardID: dashboard), tokens)
        KeychainHelper.saveDashboardCookies(Data("newer".utf8), dashboardID: dashboard)
        XCTAssertEqual(KeychainHelper.FileBackend(url: url).data(for: scoped("hermes-conduit.dashboard-cookies.v1.\(dashboard.uuidString)")), Data("newer".utf8))
        KeychainHelper.clearDashboardCookies(dashboardID: dashboard)
        XCTAssertNil(KeychainHelper.loadDashboardCookies(dashboardID: dashboard))
    }

    func testBuild162RegistryAndSessionsSurviveTwoFreshLaunches() throws {
        let url = credentialsURL()
        let dashboardA = UUID(uuidString: "9B3E6DBA-6C34-4E99-9CB3-2B9F5EA8F981")!
        let dashboardB = UUID(uuidString: "9E991DF1-3385-4A6C-AF49-9D9D01A9A445")!
        let addressA = "https://mac.example.test/hermes"
        let addressB = "https://vps.example.test"
        let registry = SavedDashboardRegistry(
            activeDashboardID: dashboardB,
            dashboards: [
                SavedDashboard(id: dashboardA, label: "Mac", normalizedURL: addressA),
                SavedDashboard(id: dashboardB, label: "VPS", normalizedURL: addressB),
            ]
        )
        let registryData = try JSONEncoder().encode(registry)
        let cookieA = try JSONEncoder().encode([
            Build162Cookie(name: "mac-session", value: "fixture-cookie-a", domain: ".mac.example.test")
        ])
        let cookieB = try JSONEncoder().encode([
            Build162Cookie(name: "vps-session", value: "fixture-cookie-b", domain: "vps.example.test")
        ])
        let credentialsA = DashboardCredentials(
            baseURL: addressA,
            username: "fixture-user-a",
            password: "fixture-password-a",
            requiresFaceID: true
        )
        let tokensB = NativeOAuthTokenSet(
            accessToken: "fixture-access-b",
            refreshToken: "fixture-refresh-b",
            expiresAt: 4_102_444_800,
            provider: "fixture-provider",
            userID: "fixture-user-b"
        )
        let headers = [
            "https://mac.example.test": [CustomHeader(name: "X-Proxy-Route", value: "fixture-mac-route")],
            "https://vps.example.test": [CustomHeader(name: "X-Proxy-Route", value: "fixture-vps-route")],
        ]
        let headersData = try JSONEncoder().encode(headers)
        let records = [
            try build162Record(KeychainHelper.dashboardRegistryAccount, registryData),
            try build162Record("hermes-conduit.connection.v1.\(dashboardA.uuidString)", json(HermesConnection(baseUrl: addressA, ticket: "fixture-ticket-a"))),
            try build162Record("hermes-conduit.connection.v1.\(dashboardB.uuidString)", json(HermesConnection(baseUrl: addressB, ticket: "fixture-ticket-b"))),
            try build162Record("hermes-conduit.credentials.v1.\(dashboardA.uuidString)", json(credentialsA)),
            try build162Record("hermes-conduit.dashboard-cookies.v1.\(dashboardA.uuidString)", cookieA),
            try build162Record("hermes-conduit.dashboard-cookies.v1.\(dashboardB.uuidString)", cookieB),
            try build162Record("hermes-conduit.native-oauth-tokens.v1.\(dashboardB.uuidString)", json(tokensB)),
            try build162Record("hermes-conduit.custom-headers.v1", headersData),
        ]
        try writeBuild162Fixture(records, to: url)

        let suite = "Build162Continuity.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for _ in 0..<2 {
            // A new backend object models a new Conduit process reopening the
            // build-162 credentials.plist in its existing sandbox container.
            KeychainHelper.useBackendForTesting(KeychainHelper.FileBackend(url: url))
            let appState = AppState(defaults: defaults, loadSavedConnection: false)

            XCTAssertEqual(appState.savedDashboardRegistry, registry)
            XCTAssertEqual(appState.savedDashboardRegistry.activeDashboardID, dashboardB)
            XCTAssertEqual(appState.savedSignIn(for: dashboardA), .biometric)
            XCTAssertEqual(appState.savedSignIn(for: dashboardB), .session)
            XCTAssertEqual(KeychainHelper.loadConnection(dashboardID: dashboardA)?.ticket, "fixture-ticket-a")
            XCTAssertEqual(KeychainHelper.loadConnection(dashboardID: dashboardB)?.ticket, "fixture-ticket-b")
            XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: dashboardA), credentialsA)
            XCTAssertEqual(KeychainHelper.loadNativeOAuthTokens(dashboardID: dashboardB), tokensB)
            XCTAssertEqual(KeychainHelper.loadDashboardCookies(dashboardID: dashboardA), cookieA)
            XCTAssertEqual(KeychainHelper.loadDashboardCookies(dashboardID: dashboardB), cookieB)
            XCTAssertEqual(DashboardCookiePersistence.mirroredCookies(dashboardID: dashboardA).first?.value, "fixture-cookie-a")
            XCTAssertEqual(DashboardCookiePersistence.mirroredCookies(dashboardID: dashboardB).first?.value, "fixture-cookie-b")

            let headerStore = CustomHeaderStore(
                load: { KeychainHelper.loadCustomHeaders() },
                persist: { KeychainHelper.saveCustomHeaders($0) }
            )
            let macRequest = URLRequest(url: URL(string: "wss://mac.example.test/hermes/api/ws")!)
                .applyingProxyHeaders(cloudflare: nil, store: headerStore)
            let vpsRequest = URLRequest(url: URL(string: "wss://vps.example.test/api/ws")!)
                .applyingProxyHeaders(cloudflare: nil, store: headerStore)
            let externalRequest = URLRequest(url: URL(string: "wss://voice.example.test/live")!)
                .applyingProxyHeaders(cloudflare: nil, store: headerStore)
            XCTAssertEqual(macRequest.value(forHTTPHeaderField: "X-Proxy-Route"), "fixture-mac-route")
            XCTAssertEqual(vpsRequest.value(forHTTPHeaderField: "X-Proxy-Route"), "fixture-vps-route")
            XCTAssertNil(externalRequest.value(forHTTPHeaderField: "X-Proxy-Route"))

            let reopened = KeychainHelper.FileBackend(url: url)
            XCTAssertEqual(reopened.data(for: scoped(KeychainHelper.dashboardRegistryAccount)), registryData)
            XCTAssertEqual(reopened.data(for: scoped("hermes-conduit.custom-headers.v1")), headersData)
        }
    }

    func testBuild162LegacyRecordsMigrateOnceAndKeepOriginBoundHeaders() throws {
        let url = credentialsURL()
        let legacyURL = "https://legacy.example.test/hermes"
        let credentials = DashboardCredentials(
            baseURL: legacyURL,
            username: "fixture-legacy-user",
            password: "fixture-legacy-password",
            requiresFaceID: false
        )
        let cookieData = try JSONEncoder().encode([
            Build162Cookie(name: "legacy-session", value: "fixture-legacy-cookie", domain: ".legacy.example.test")
        ])
        // An origin-bound Cloudflare record moves with the dashboard. (A
        // pre-origin one migrates as upstream copies it, unbound, so it is
        // never sent until re-entered.)
        let legacyCloudflare = Data(#"{"clientID":"fixture-cloudflare-id","clientSecret":"fixture-cloudflare-secret","origin":"https://legacy.example.test/hermes"}"#.utf8)
        let headers = [
            "https://legacy.example.test": [CustomHeader(name: "X-Proxy-Route", value: "fixture-legacy-route")]
        ]
        let headersData = try JSONEncoder().encode(headers)
        try writeBuild162Fixture([
            try build162Record("hermes-conduit.connection.v1", json(HermesConnection(baseUrl: legacyURL, ticket: "fixture-legacy-ticket"))),
            try build162Record("hermes-conduit.credentials.v1", json(credentials)),
            try build162Record("hermes-conduit.dashboard-cookies.v1", cookieData),
            try build162Record("hermes-conduit.cloudflare-access.v1", legacyCloudflare),
            try build162Record("hermes-conduit.custom-headers.v1", headersData),
        ], to: url)

        let suite = "Build162LegacyMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(legacyURL, forKey: "conduit.dashboardURL")
        defer { defaults.removePersistentDomain(forName: suite) }

        var firstDashboardID: UUID?
        for _ in 0..<2 {
            KeychainHelper.useBackendForTesting(KeychainHelper.FileBackend(url: url))
            let appState = AppState(defaults: defaults, loadSavedConnection: false)
            let dashboardID = try XCTUnwrap(appState.savedDashboardRegistry.activeDashboardID)
            if let firstDashboardID {
                XCTAssertEqual(dashboardID, firstDashboardID, "The committed registry identity must survive a fresh launch")
            } else {
                firstDashboardID = dashboardID
            }
            XCTAssertEqual(appState.savedDashboardRegistry.dashboards.map(\.normalizedURL), [legacyURL])
            XCTAssertEqual(appState.savedSignIn(for: dashboardID), .password)
            XCTAssertEqual(KeychainHelper.loadConnection(dashboardID: dashboardID)?.ticket, "fixture-legacy-ticket")
            XCTAssertEqual(KeychainHelper.loadCredentials(dashboardID: dashboardID), credentials)
            XCTAssertEqual(KeychainHelper.loadDashboardCookies(dashboardID: dashboardID), cookieData)
            XCTAssertEqual(DashboardCookiePersistence.mirroredCookies(dashboardID: dashboardID).first?.value, "fixture-legacy-cookie")
            XCTAssertEqual(KeychainHelper.loadCloudflareAccess(dashboardID: dashboardID, for: legacyURL)?.clientID, "fixture-cloudflare-id")
            XCTAssertEqual(KeychainHelper.loadCloudflareKeychainRecord(dashboardID: dashboardID)?.origin, legacyURL)

            let headerStore = CustomHeaderStore(
                load: { KeychainHelper.loadCustomHeaders() },
                persist: { KeychainHelper.saveCustomHeaders($0) }
            )
            let sameOrigin = URLRequest(url: URL(string: "wss://legacy.example.test/hermes/api/ws")!)
                .applyingProxyHeaders(cloudflare: nil, store: headerStore)
            let otherOrigin = URLRequest(url: URL(string: "wss://elsewhere.example.test/api/ws")!)
                .applyingProxyHeaders(cloudflare: nil, store: headerStore)
            XCTAssertEqual(sameOrigin.value(forHTTPHeaderField: "X-Proxy-Route"), "fixture-legacy-route")
            XCTAssertNil(otherOrigin.value(forHTTPHeaderField: "X-Proxy-Route"))
            XCTAssertEqual(KeychainHelper.loadCustomHeaders(), headers)
        }
        XCTAssertNil(KeychainHelper.loadConnection(), "Legacy records retire only after the scoped state and registry commit")
        XCTAssertNil(KeychainHelper.loadCredentials())
        XCTAssertNil(KeychainHelper.loadDashboardCookies())
        XCTAssertNil(KeychainHelper.loadCloudflareKeychainRecord())
    }

    private struct Build162Record: Codable {
        let service: String?
        let account: String?
        let data: Data
        let accessibility: String?
    }

    private struct Build162Cookie: Codable {
        let name: String
        let value: String
        let domain: String
        var path = "/"
        var expiresDate: Date? = nil
        var isSecure = true
        var isHTTPOnly = true
        var sameSitePolicy: String? = nil
    }

    private func json<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    /// Build 162's FileBackend persisted this binary plist record shape;
    /// only the account payloads below are generated as synthetic fixtures.
    private func build162Record(_ account: String, _ data: Data) throws -> Build162Record {
        Build162Record(
            service: "com.milim.conduit",
            account: account,
            data: data,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    private func writeBuild162Fixture(_ records: [Build162Record], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(records).write(to: url)
    }
}
#endif
