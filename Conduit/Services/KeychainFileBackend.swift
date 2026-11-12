//
//  KeychainFileBackend.swift
//  Conduit
//
//  Where the Mac build keeps KeychainHelper's records. Mac Catalyst always
//  uses the data protection keychain, which an app signed to run locally
//  (no team, no provisioning profile) can't reach: every SecItem call fails
//  with errSecMissingEntitlement. So the Mac build keeps them in one file in
//  its sandbox container instead (scripts/mac-catalyst/ConduitMac.entitlements),
//  readable only by the user's account, and out of backups as a
//  ThisDeviceOnly keychain item is.
//

#if targetEnvironment(macCatalyst)
import Foundation
import os
import Security

extension KeychainHelper {
    /// Records matched as SecItem matches them: every attribute a query
    /// names must agree, so KeychainHelper's legacy query (no service) reads,
    /// updates and deletes the account's record whatever its service.
    final class FileBackend: Backend {
        private struct Record: Codable {
            var service: String?
            var account: String?
            var data: Data
            var accessibility: String?
        }

        /// What the records were read from, so a write by another process
        /// (a second copy of Conduit for Mac, `open -n`) is read again rather
        /// than overwritten.
        private struct Stamp: Equatable {
            let modified: Date?
            let size: Int?
        }

        private static let log = Logger(subsystem: "com.milim.relay", category: "keychain")
        static let shared = FileBackend(url: defaultURL)

        private let url: URL
        private let lock = NSLock()
        private var records: [Record]?
        private var stamp: Stamp?

        init(url: URL) {
            self.url = url
        }

        static var defaultURL: URL {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base.appendingPathComponent("Credentials", isDirectory: true)
                .appendingPathComponent("credentials.plist")
        }

        func data(for query: [String: Any]) -> Data? {
            lock.lock()
            defer { lock.unlock() }
            return withFileLock { loaded().first { Self.matches($0, query) }?.data }
        }

        func update(_ data: Data, for query: [String: Any]) -> Int32 {
            change { records in
                var found = false
                for index in records.indices where Self.matches(records[index], query) {
                    records[index].data = data
                    found = true
                }
                return found ? errSecSuccess : errSecItemNotFound
            }
        }

        func add(_ query: [String: Any]) -> Int32 {
            guard let data = query[kSecValueData as String] as? Data else { return errSecParam }
            let record = Record(
                service: query[kSecAttrService as String] as? String,
                account: query[kSecAttrAccount as String] as? String,
                data: data,
                accessibility: query[kSecAttrAccessible as String] as? String
            )
            return change { records in
                guard !records.contains(where: { $0.service == record.service && $0.account == record.account }) else {
                    return errSecDuplicateItem
                }
                records.append(record)
                return errSecSuccess
            }
        }

        func delete(_ query: [String: Any]) {
            _ = change { records in
                let count = records.count
                records.removeAll { Self.matches($0, query) }
                return records.count == count ? errSecItemNotFound : errSecSuccess
            }
        }

        func setAccessibility(_ accessibility: CFString, for query: [String: Any]) -> Int32 {
            change { records in
                var found = false
                for index in records.indices where Self.matches(records[index], query) {
                    records[index].accessibility = accessibility as String
                    found = true
                }
                return found ? errSecSuccess : errSecItemNotFound
            }
        }

        // MARK: - Internals

        private static func matches(_ record: Record, _ query: [String: Any]) -> Bool {
            if let service = query[kSecAttrService as String] as? String, record.service != service { return false }
            if let account = query[kSecAttrAccount as String] as? String, record.account != account { return false }
            return true
        }

        /// Applies `body` and writes the result; nothing changes unless the
        /// file was written, so a failed write reads as the keychain refusing.
        private func change(_ body: (inout [Record]) -> Int32) -> Int32 {
            lock.lock()
            defer { lock.unlock() }
            return withFileLock {
                var next = loaded()
                let status = body(&next)
                guard status == errSecSuccess else { return status }
                do {
                    stamp = try write(next)
                } catch {
                    Self.log.error("Credentials not saved: \(String(describing: type(of: error)), privacy: .public)")
                    return errSecIO
                }
                records = next
                return errSecSuccess
            }
        }

        /// Runs `body` holding a lock beside the file, as E2ESeenStore does,
        /// so two copies of Conduit for Mac never read and write it at once.
        /// Goes ahead unlocked when the lock can't be had within a second.
        private func withFileLock<T>(_ body: () -> T) -> T {
            let descriptor = open(url.path + ".lock", O_CREAT | O_RDWR, 0o600)
            guard descriptor >= 0 else { return body() }
            defer { close(descriptor) }
            var locked = false
            for _ in 0..<20 {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    locked = true
                    break
                }
                usleep(50_000)
            }
            defer { if locked { flock(descriptor, LOCK_UN) } }
            return body()
        }

        private static func stamp(at url: URL) -> Stamp? {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            return Stamp(modified: attributes[.modificationDate] as? Date, size: (attributes[.size] as? NSNumber)?.intValue)
        }

        private func loaded() -> [Record] {
            // Taken before the read, so a file another copy swaps in after it
            // has a different stamp and is read next time.
            let onDisk = Self.stamp(at: url)
            if let records, onDisk == stamp { return records }
            var read: [Record] = []
            var readStamp = onDisk
            if onDisk != nil {
                do {
                    read = try PropertyListDecoder().decode([Record].self, from: Data(contentsOf: url))
                } catch {
                    // Kept for a later build to read: the next save starts a
                    // new file instead of writing over every record in it.
                    Self.log.error("Credentials file unreadable, set aside: \(String(describing: type(of: error)), privacy: .public)")
                    let aside = url.deletingPathExtension()
                        .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).plist")
                    try? FileManager.default.moveItem(at: url, to: aside)
                    readStamp = Self.stamp(at: url)
                }
            }
            records = read
            stamp = readStamp
            return read
        }

        /// Writes `records` and returns the written file's stamp.
        private func write(_ records: [Record]) throws -> Stamp? {
            let manager = FileManager.default
            let directory = url.deletingLastPathComponent()
            if !manager.fileExists(atPath: directory.path) {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            // An existing directory may come from an older build or a
            // restore. Reapply the privacy flag on every write, and refuse
            // to save credentials if setting it fails.
            var excluded = URL(fileURLWithPath: directory.path, isDirectory: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            // Made owner-only before any record is in it, then swapped in whole.
            let staging = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
            guard manager.createFile(atPath: staging.path, contents: try encoder.encode(records),
                                     attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            // The swap keeps the staged file's date and size.
            let written = Self.stamp(at: staging)
            do {
                if manager.fileExists(atPath: url.path) {
                    _ = try manager.replaceItemAt(url, withItemAt: staging)
                } else {
                    try manager.moveItem(at: staging, to: url)
                }
            } catch {
                try? manager.removeItem(at: staging)
                throw error
            }
            return written
        }
    }
}
#endif
