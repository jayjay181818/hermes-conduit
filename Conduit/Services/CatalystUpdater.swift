import Foundation
import CryptoKit

/// The Mac release tag is also its version manifest. Build numbers are the
/// monotonic ordering key across macOS hotfixes.
struct MacReleaseVersion: Equatable {
    let major: Int
    let minor: Int
    let patch: Int
    let build: Int

    static func parse(tag: String) -> MacReleaseVersion? {
        guard tag.hasPrefix("macos/v") else { return nil }
        let parts = tag.dropFirst("macos/v".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[1] == "build", !parts[0].isEmpty else { return nil }
        let versionParts = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard versionParts.count == 3,
              let major = Self.canonicalInteger(versionParts[0]),
              let minor = Self.canonicalInteger(versionParts[1]),
              let patch = Self.canonicalInteger(versionParts[2]),
              let build = Self.canonicalInteger(parts[2]),
              build > 0 else { return nil }
        return MacReleaseVersion(major: major, minor: minor, patch: patch, build: build)
    }

    private static func canonicalInteger<S: StringProtocol>(_ value: S) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isNumber }),
              let number = Int(value), String(number) == value else { return nil }
        return number
    }

    var marketingVersion: String { "\(major).\(minor).\(patch)" }
    var tag: String { "macos/v\(marketingVersion)-build-\(build)" }
}

struct GitHubMacRelease: Decodable {
    struct Asset: Decodable {
        let id: Int
        let name: String
        let size: Int
        let url: String
        let digest: String?
    }

    let tagName: String
    let draft: Bool
    let prerelease: Bool
    let publishedAt: String?
    let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft, prerelease, assets
        case publishedAt = "published_at"
    }
}

struct MacReleaseDescriptor: Equatable {
    let version: MacReleaseVersion
    let assetID: Int
    let assetSize: Int
    let assetURL: URL
    let sha256: String
}

enum MacUpdaterError: LocalizedError, Equatable {
    case noPublishedRelease
    case invalidRelease(String)
    case invalidAsset(String)
    case httpStatus(Int)
    case responseTooLarge
    case downloadFailed(String)
    case digestMismatch
    case packageNotAvailable

    var errorDescription: String? {
        switch self {
        case .noPublishedRelease:
            return AppLocalization.string("No published Mac update is available yet.")
        case .invalidRelease(let reason):
            return AppLocalization.string("Mac update metadata is invalid: \(reason)")
        case .invalidAsset(let reason):
            return AppLocalization.string("Mac update metadata is invalid: \(reason)")
        case .httpStatus:
            return AppLocalization.string("Mac update check failed.")
        case .responseTooLarge:
            return AppLocalization.string("Mac update check failed.")
        case .downloadFailed:
            return AppLocalization.string("Mac update check failed.")
        case .digestMismatch:
            return AppLocalization.string("The downloaded package failed SHA-256 verification.")
        case .packageNotAvailable:
            return AppLocalization.string("Check for Updates")
        }
    }
}

enum MacReleaseCatalog {
    static let packageName = "Conduit-macOS-arm64.pkg"
    static let maximumAssetSize = 512 * 1024 * 1024
    static let repository = "jayjay181818/hermes-conduit"
    static let apiHost = "api.github.com"

    static func latestUpdate(in releases: [GitHubMacRelease], currentBuild: Int) throws -> MacReleaseDescriptor? {
        let publishedMacReleases = releases.filter {
            !$0.draft && !$0.prerelease && $0.publishedAt?.isEmpty == false && $0.tagName.hasPrefix("macos/")
        }
        guard !publishedMacReleases.isEmpty else { throw MacUpdaterError.noPublishedRelease }

        let parsed = try publishedMacReleases.map { release -> (GitHubMacRelease, MacReleaseVersion) in
            guard let version = MacReleaseVersion.parse(tag: release.tagName) else {
                throw MacUpdaterError.invalidRelease("the tag \(release.tagName) is not canonical")
            }
            return (release, version)
        }
        let newestBuild = parsed.map(\.1.build).max()!
        let newest = parsed.filter { $0.1.build == newestBuild }
        guard newest.count == 1, let selected = newest.first else {
            throw MacUpdaterError.invalidRelease("multiple releases use build \(newestBuild)")
        }
        guard newestBuild > currentBuild else { return nil }

        let matchingAssets = selected.0.assets.filter { $0.name == packageName }
        guard matchingAssets.count == 1, let asset = matchingAssets.first else {
            throw MacUpdaterError.invalidAsset("the release must contain exactly one \(packageName)")
        }
        guard asset.id > 0,
              asset.size > 0,
              asset.size <= maximumAssetSize,
              let digest = asset.digest,
              digest.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil,
              let url = URL(string: asset.url),
              isAssetEndpoint(url, assetID: asset.id) else {
            throw MacUpdaterError.invalidAsset("asset ID, size, SHA-256 digest, or repository endpoint is invalid")
        }
        return MacReleaseDescriptor(
            version: selected.1,
            assetID: asset.id,
            assetSize: asset.size,
            assetURL: url,
            sha256: String(digest.dropFirst("sha256:".count))
        )
    }

    static func releaseListURL(page: Int = 1) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.path = "/repos/\(repository)/releases"
        components.queryItems = [URLQueryItem(name: "per_page", value: "100")]
        if page > 1 { components.queryItems?.append(URLQueryItem(name: "page", value: String(page))) }
        return components.url!
    }

    static func isAssetEndpoint(_ url: URL, assetID: Int) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https"
            && components.host == apiHost
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && components.path == "/repos/\(repository)/releases/assets/\(assetID)"
            && components.query == nil
            && components.fragment == nil
    }

    static func isAssetRedirect(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme == "https"
            && components.host == "release-assets.githubusercontent.com"
            && (components.port == nil || components.port == 443)
            && components.user == nil
            && components.password == nil
            && components.fragment == nil
    }

    static func nextPage(from header: String?, currentPage: Int) throws -> Int? {
        guard let header else { return nil }
        for link in header.split(separator: ",") {
            let fields = link.split(separator: ";", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 2, fields[1].contains("rel=\"next\"") else { continue }
            guard fields[0].first == "<", fields[0].last == ">",
                  let url = URL(string: String(fields[0].dropFirst().dropLast())),
                  isReleaseListPage(url, expectedPage: currentPage + 1) else {
                throw MacUpdaterError.invalidRelease("GitHub returned an unexpected pagination URL")
            }
            return currentPage + 1
        }
        return nil
    }

    private static func isReleaseListPage(_ url: URL, expectedPage: Int) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "https", components.host == apiHost,
              components.path == "/repos/\(repository)/releases",
              components.user == nil, components.password == nil,
              components.fragment == nil else { return false }
        let items = components.queryItems ?? []
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        return items.count == 2 && values.count == 2
            && values["per_page"] == "100"
            && values["page"] == String(expectedPage)
    }
}

enum MacReleaseDigest {
    static func matches(data: Data, expectedHex: String) -> Bool {
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return actual == expectedHex
    }

    static func sha256(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

#if targetEnvironment(macCatalyst)
import Combine
import SwiftUI
import UIKit

@MainActor
final class CatalystUpdaterModel: ObservableObject {
    @Published private(set) var update: MacReleaseDescriptor?
    @Published private(set) var status = AppLocalization.string("Check for Updates")
    @Published private(set) var isWorking = false
    @Published private(set) var verifiedPackageURL: URL?

    private let service = MacReleaseService()

    func checkForUpdates() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        status = AppLocalization.string("Checking for Updates…")
        discardVerifiedPackage()
        do {
            guard let buildString = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                  let currentBuild = Int(buildString), currentBuild > 0 else {
                throw MacUpdaterError.invalidRelease("the installed Mac build number is missing or invalid")
            }
            update = try await service.latestUpdate(currentBuild: currentBuild)
            if let update {
                status = AppLocalization.string("Version \(update.version.marketingVersion) is available.")
            } else {
                status = AppLocalization.string("No new Mac update is available.")
            }
        } catch {
            update = nil
            status = error.localizedDescription
        }
    }

    func downloadVerifiedPackage() async throws -> URL {
        guard !isWorking, let update else { throw MacUpdaterError.packageNotAvailable }
        isWorking = true
        defer { isWorking = false }
        do {
            let fileURL = try await service.download(update)
            verifiedPackageURL = fileURL
            status = AppLocalization.string("Version \(update.version.marketingVersion) is available.")
            return fileURL
        } catch {
            status = error.localizedDescription
            throw error
        }
    }

    func markSaved() {
        discardVerifiedPackage()
        status = AppLocalization.string("Verified Mac update package saved.")
    }

    func discardVerifiedPackage() {
        if let verifiedPackageURL { try? FileManager.default.removeItem(at: verifiedPackageURL.deletingLastPathComponent()) }
        verifiedPackageURL = nil
    }

    func markInstallerOpenFailure(at url: URL) {
        status = AppLocalization.string("Open the saved package from Finder to continue: \(url.path)")
    }

    func markSaveFailure(_ error: Error) {
        status = AppLocalization.string("Could not save \(error.localizedDescription).")
    }
}

private struct MacReleaseService {
    func latestUpdate(currentBuild: Int) async throws -> MacReleaseDescriptor? {
        let releases = try await fetchReleases()
        return try MacReleaseCatalog.latestUpdate(in: releases, currentBuild: currentBuild)
    }

    func download(_ release: MacReleaseDescriptor) async throws -> URL {
        try await MacPackageDownloader.download(release)
    }

    private func fetchReleases() async throws -> [GitHubMacRelease] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: MacRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var page = 1
        var releases: [GitHubMacRelease] = []
        while page <= 20 {
            var request = URLRequest(url: MacReleaseCatalog.releaseListURL(page: page), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Hermes-Conduit-Mac-Updater", forHTTPHeaderField: "User-Agent")
            request.httpShouldHandleCookies = false
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.url == request.url else {
                throw MacUpdaterError.invalidRelease("the metadata response came from an unexpected URL")
            }
            guard http.statusCode == 200 else { throw MacUpdaterError.httpStatus(http.statusCode) }
            guard data.count <= 5 * 1024 * 1024 else { throw MacUpdaterError.responseTooLarge }
            do {
                releases.append(contentsOf: try JSONDecoder().decode([GitHubMacRelease].self, from: data))
            } catch {
                throw MacUpdaterError.invalidRelease("GitHub returned unreadable release metadata")
            }
            guard let next = try MacReleaseCatalog.nextPage(from: http.value(forHTTPHeaderField: "Link"), currentPage: page) else { break }
            page = next
        }
        guard page <= 20 else { throw MacUpdaterError.invalidRelease("the release list exceeded the safe pagination limit") }
        return releases
    }
}

struct MacPackageDownloader {
    static func download(
        _ release: MacReleaseDescriptor,
        configuration: URLSessionConfiguration = .ephemeral,
        maximumSize: Int = MacReleaseCatalog.maximumAssetSize
    ) async throws -> URL {
        guard MacReleaseCatalog.isAssetEndpoint(release.assetURL, assetID: release.assetID),
              maximumSize > 0,
              maximumSize <= MacReleaseCatalog.maximumAssetSize,
              release.assetSize > 0,
              release.assetSize <= maximumSize else {
            throw MacUpdaterError.invalidAsset("the asset endpoint or declared package size is invalid")
        }
        let safeConfiguration = configuration
        safeConfiguration.httpCookieStorage = nil
        safeConfiguration.httpShouldSetCookies = false
        safeConfiguration.urlCredentialStorage = nil
        safeConfiguration.httpAdditionalHeaders = nil
        var packageRequest = URLRequest(url: release.assetURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        packageRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        packageRequest.setValue("Hermes-Conduit-Mac-Updater", forHTTPHeaderField: "User-Agent")
        packageRequest.httpShouldHandleCookies = false
        let downloaded = try await BoundedMacPackageDownload(
            maximumSize: release.assetSize,
            expectedAssetURL: release.assetURL,
            configuration: safeConfiguration
        ).run(packageRequest)
        do {
            let values = try downloaded.resourceValues(forKeys: [.fileSizeKey])
            guard values.fileSize == release.assetSize else { throw MacUpdaterError.invalidAsset("download size did not match release metadata") }
            guard try MacReleaseDigest.sha256(fileAt: downloaded) == release.sha256 else { throw MacUpdaterError.digestMismatch }
            return downloaded
        } catch {
            try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent())
            throw error
        }
    }
}

private final class MacRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class BoundedMacPackageDownload: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let maximumSize: Int
    private let expectedAssetURL: URL
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var resultURL: URL?
    private var failure: Error?
    private var directoryURL: URL?
    private var output: FileHandle?
    private var receivedBytes = 0

    private let configuration: URLSessionConfiguration

    init(maximumSize: Int, expectedAssetURL: URL, configuration: URLSessionConfiguration = .ephemeral) {
        self.maximumSize = maximumSize
        self.expectedAssetURL = expectedAssetURL
        self.configuration = configuration
    }

    func run(_ request: URLRequest) async throws -> URL {
        guard request.url == expectedAssetURL,
              request.httpMethod == "GET",
              request.httpBody == nil,
              request.httpBodyStream == nil else {
            throw MacUpdaterError.invalidAsset("the request did not use the expected GitHub asset endpoint")
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 600
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            session?.dataTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard response.url == expectedAssetURL,
              let url = request.url,
              MacReleaseCatalog.isAssetRedirect(url) else {
            failure = MacUpdaterError.invalidAsset("GitHub redirected the package to an unapproved host")
            completionHandler(nil)
            task.cancel()
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = MacUpdaterError.invalidAsset("GitHub returned an unexpected package response")
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 else {
            failure = MacUpdaterError.httpStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }
        guard let url = http.url,
              url == expectedAssetURL || MacReleaseCatalog.isAssetRedirect(url) else {
            failure = MacUpdaterError.invalidAsset("the package response URL is outside the approved GitHub asset path")
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength < 0 || http.expectedContentLength <= Int64(maximumSize) else {
            failure = MacUpdaterError.responseTooLarge
            completionHandler(.cancel)
            return
        }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Conduit-Mac-Update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let package = directory.appendingPathComponent(MacReleaseCatalog.packageName)
            guard FileManager.default.createFile(atPath: package.path, contents: nil) else {
                throw MacUpdaterError.downloadFailed("the temporary package file could not be created")
            }
            directoryURL = directory
            resultURL = package
            output = try FileHandle(forWritingTo: package)
            self.response = http
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        receivedBytes += data.count
        guard receivedBytes <= maximumSize else {
            failure = MacUpdaterError.responseTooLarge
            dataTask.cancel()
            return
        }
        do {
            try output?.write(contentsOf: data)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { failure = failure ?? MacUpdaterError.downloadFailed(error.localizedDescription) }
        do { try output?.close() } catch { failure = failure ?? error }
        output = nil
        if failure == nil, let expectedLength = response?.expectedContentLength,
           expectedLength >= 0, Int64(receivedBytes) != expectedLength {
            failure = MacUpdaterError.invalidAsset("download size did not match the response length")
        }
        if failure == nil, (response == nil || receivedBytes == 0) {
            failure = MacUpdaterError.downloadFailed("the download ended without a package file")
        }
        if let failure {
            if let directoryURL { try? FileManager.default.removeItem(at: directoryURL) }
            continuation?.resume(throwing: failure)
        } else if let resultURL {
            continuation?.resume(returning: resultURL)
        } else {
            continuation?.resume(throwing: MacUpdaterError.downloadFailed("the download ended without a package file"))
        }
        continuation = nil
        session.finishTasksAndInvalidate()
    }
}

enum CatalystUpdaterPresenter {
    static func present() {
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive }),
                  let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
            var presenter = root
            while let presented = presenter.presentedViewController { presenter = presented }
            let controller = UIHostingController(rootView: CatalystUpdaterView())
            controller.modalPresentationStyle = .formSheet
            presenter.present(controller, animated: true)
        }
    }
}

struct CatalystUpdaterCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(AppLocalization.string("Check for Updates")) { CatalystUpdaterPresenter.present() }
        }
    }
}

struct CatalystUpdaterView: View {
    @StateObject private var updater = CatalystUpdaterModel()
    @State private var downloadTask: Task<Void, Never>?
    @State private var showExporter = false
    @State private var showFallback = false
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Form {
                Section(AppLocalization.string("Check for Updates")) {
                    Text(updater.status).textSelection(.enabled)
                    Button(AppLocalization.string("Check for Updates")) { Task { await updater.checkForUpdates() } }
                        .disabled(updater.isWorking)
                    if updater.update != nil {
                        Button(AppLocalization.string("Prepare file for download")) {
                            downloadTask = Task {
                                do {
                                    _ = try await updater.downloadVerifiedPackage()
                                    guard !Task.isCancelled else {
                                        updater.discardVerifiedPackage()
                                        return
                                    }
                                    showExporter = true
                                } catch {
                                    if !Task.isCancelled { showError = true }
                                }
                            }
                        }
                        .disabled(updater.isWorking)
                    }
                    if updater.isWorking { ProgressView() }
                }
                Section {
                    Text(AppLocalization.string("Apple Installer checks the package signature and asks you to confirm installation."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(AppLocalization.string("Check for Updates"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalization.string("Done")) {
                        UIApplication.shared.connectedScenes
                            .compactMap { $0 as? UIWindowScene }
                            .flatMap(\.windows)
                            .first(where: \.isKeyWindow)?
                            .rootViewController?.dismiss(animated: true)
                    }
                }
            }
            .sheet(isPresented: $showExporter) {
                if let packageURL = updater.verifiedPackageURL {
                    CatalystPackageExporter(fileURL: packageURL) { result in
                        showExporter = false
                        switch result {
                        case .success(let url):
                            updater.markSaved()
                            let hasScopedAccess = url.startAccessingSecurityScopedResource()
                            UIApplication.shared.open(url, options: [:]) { opened in
                                if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
                                if !opened { updater.markInstallerOpenFailure(at: url); showFallback = true }
                            }
                        case .failure(let error):
                            updater.discardVerifiedPackage()
                            if (error as NSError).code != NSUserCancelledError {
                                updater.markSaveFailure(error)
                                showError = true
                            }
                        }
                    }
                }
            }
            .alert(AppLocalization.string("Update"), isPresented: Binding(
                get: { showFallback || showError },
                set: { if !$0 { showFallback = false; showError = false } }
            )) {
                Button(AppLocalization.string("OK"), role: .cancel) { showFallback = false; showError = false }
            } message: {
                Text(updater.status)
            }
        }
        .frame(minWidth: 460, minHeight: 300)
        .task { await updater.checkForUpdates() }
        .onDisappear {
            downloadTask?.cancel()
            if !showExporter { updater.discardVerifiedPackage() }
        }
    }
}

private struct CatalystPackageExporter: UIViewControllerRepresentable {
    let fileURL: URL
    let completion: (Result<URL, Error>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Result<URL, Error>) -> Void
        init(completion: @escaping (Result<URL, Error>) -> Void) { self.completion = completion }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                completion(.failure(MacUpdaterError.downloadFailed("the save location returned no package")))
                return
            }
            completion(.success(url))
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion(.failure(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError)))
        }
    }
}
#endif
