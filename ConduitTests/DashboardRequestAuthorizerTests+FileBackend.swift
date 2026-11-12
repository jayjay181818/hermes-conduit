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
                let size = getxattr(path, name, nil, 0, 0, 0)
                if size < 0 {
                    if errno == ENOATTR { return nil }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard size > 0, size <= 1024 else { throw CocoaError(.fileReadCorruptFile) }
                var data = Data(count: size)
                let copied = data.withUnsafeMutableBytes { bytes in
                    getxattr(path, name, bytes.baseAddress, bytes.count, 0, 0)
                }
                guard copied == size else { throw CocoaError(.fileReadCorruptFile) }
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
}
#endif
