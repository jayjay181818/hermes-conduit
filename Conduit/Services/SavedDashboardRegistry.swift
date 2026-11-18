//
//  SavedDashboardRegistry.swift
//  Conduit
//
//  Multi-dashboard identity for issue #148: a stable, app-generated UUID —
//  never the normalized URL — is each dashboard's durable identity, so the
//  saved entry survives address changes (Tailnet name moves, port edits) and
//  two servers that both answer on profile "default" / session "default"
//  never share auth state.
//
//  The registry itself carries only metadata (id, label, normalized URL).
//  Every reusable authentication record — connection ticket, password
//  credentials, Cloudflare service token, dashboard cookie mirror — lives in
//  its own Keychain record whose account name embeds the dashboard UUID, so
//  dashboard A's state can never be read or cleared through dashboard B.
//
//  Storage is the Keychain, not UserDefaults: the registry names the servers
//  the user authenticates against, which is connection data and follows the
//  same privacy intent as the records it indexes.
//

import Foundation

/// One saved Hermes dashboard. The UUID is the identity; `normalizedURL` is
/// the current address it was last reached at.
struct SavedDashboard: Codable, Equatable, Identifiable {
    let id: UUID
    var label: String
    var normalizedURL: String
    /// The username that last signed in here, kept through Sign Out so the
    /// next sign-in starts filled in. Registries saved before it decode
    /// without one.
    var username: String?
    /// An address edited in Settings, saved for this dashboard's next
    /// reconnect: the same dashboard (its chats, profiles, appearance) moves
    /// there when it next signs in, never under the session in use.
    /// Registries saved before it decode without one.
    var pendingURL: String?
    /// Part of the combined group (Settings > Saved Dashboards, Combine
    /// Dashboards; multi-instance stage 3). Registries saved before it
    /// decode without one, which is not combined.
    var combined: Bool?

    var isCombined: Bool { combined == true }
}

/// What a saved dashboard can sign in with, without typing anything.
enum SavedSignInKind: Equatable {
    /// A saved password behind Face ID or Touch ID.
    case biometric
    /// A saved password.
    case password
    /// A saved session from a browser or single sign-on login.
    case session
    /// Nothing saved: the dashboard needs a sign-in. (Not `none`, which
    /// reads as an Optional's.)
    case signInNeeded

    var canSignInWithoutTyping: Bool { self != .signInNeeded }
}

/// The persisted multi-dashboard registry. `schemaVersion` guards future
/// shape changes; `activeDashboardID` is the dashboard the user last chose —
/// it is set at switch INTENT (before connecting), so a failed switch leaves
/// the target selected with its sign-in/repair surface instead of silently
/// falling back to the outgoing server.
struct SavedDashboardRegistry: Codable, Equatable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var activeDashboardID: UUID?
    var dashboards: [SavedDashboard]

    init(activeDashboardID: UUID? = nil, dashboards: [SavedDashboard] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.activeDashboardID = activeDashboardID
        self.dashboards = dashboards
    }

    func dashboard(with id: UUID) -> SavedDashboard? {
        dashboards.first { $0.id == id }
    }

    /// The combined group: the dashboards switched on under Combine
    /// Dashboards, once there are two or more of them. One alone is no
    /// group.
    var combinedGroupIDs: Set<UUID> {
        let combined = dashboards.filter(\.isCombined).map(\.id)
        return combined.count >= 2 ? Set(combined) : []
    }

    /// The selected dashboard's display label, if one is selected.
    var activeDashboardLabel: String? {
        activeDashboardID.flatMap { dashboard(with: $0)?.label }
    }

    /// The saved dashboard currently reached at this normalized address.
    /// Normalized URLs are unique in the registry: adoption dedupes by URL,
    /// so two saved entries can never resolve to one server.
    func dashboard(atNormalizedURL url: String) -> SavedDashboard? {
        dashboards.first { $0.normalizedURL == url }
    }

    /// The saved dashboard reached at this address, or moving there at its
    /// next reconnect.
    func dashboard(claiming url: String) -> SavedDashboard? {
        dashboard(atNormalizedURL: url) ?? dashboards.first { $0.pendingURL == url }
    }

    /// The ID a connection to this address belongs to: the saved dashboard's
    /// UUID when one exists, otherwise nil (the caller registers a new
    /// dashboard on adoption).
    func dashboardID(atNormalizedURL url: String) -> UUID? {
        dashboard(atNormalizedURL: url)?.id
    }
}

// MARK: - Label derivation

enum SavedDashboardLabel {
    /// Derives an initial display label from a dashboard address. A DNS host
    /// contributes its first label ("mac.tailnet.ts.net" → "Mac"); an IP
    /// literal stays whole ("192.168.1.5"). `existingLabels` disambiguates
    /// duplicates ("Mac", "Mac 2"), so two addresses can never render as two
    /// indistinguishable rows.
    static func derive(from baseURL: String, existingLabels: [String] = []) -> String {
        let host = URL(string: baseURL)?.host?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let base: String
        if let host, !host.isEmpty {
            // IPv6 literals (any colon) and dotted-quad IPv4 stay whole; a
            // DNS host contributes its first label.
            if host.contains(":") {
                base = host
            } else {
                let looksLikeIP = host.dropFirst().allSatisfy { $0.isNumber || $0 == "." } && host.first?.isNumber == true
                if looksLikeIP {
                    base = host
                } else {
                    let firstLabel = host.split(separator: ".").first.map(String.init) ?? host
                    base = firstLabel.localizedCapitalized
                }
            }
        } else {
            base = AppLocalization.string("Dashboard")
        }
        guard existingLabels.contains(base) else { return base }
        var candidate = base
        var counter = 2
        while existingLabels.contains(candidate) {
            candidate = "\(base) \(counter)"
            counter += 1
        }
        return candidate
    }
}

// MARK: - Secure store

/// Keychain-backed registry persistence. The record is written LAST during
/// migration — its presence is the idempotency gate, so a migration that dies
/// halfway leaves no registry and the next launch retries from legacy state.
enum SavedDashboardRegistryStore {
    static let keychainAccount = "hermes-conduit.dashboard-registry.v1"

    static func load() -> SavedDashboardRegistry? {
        guard let data = KeychainHelper.loadDashboardRegistryData(),
              let registry = try? JSONDecoder().decode(SavedDashboardRegistry.self, from: data),
              registry.schemaVersion == SavedDashboardRegistry.currentSchemaVersion else {
            return nil
        }
        return registry
    }

    /// Returns true only when the committed representation can be read back.
    /// Migration uses that readback as its destructive-cleanup boundary.
    @discardableResult
    static func save(_ registry: SavedDashboardRegistry) -> Bool {
        guard registry.schemaVersion == SavedDashboardRegistry.currentSchemaVersion,
              let data = try? JSONEncoder().encode(registry) else { return false }
        KeychainHelper.saveDashboardRegistryData(data)
        return load() == registry
    }
}

// MARK: - Legacy migration

/// The pre-multi-dashboard auth state, read once from the legacy global
/// Keychain records. Every field is optional: real installs carry partial
/// state (browser-auth dashboards have no password credentials, Face ID
/// setups still carry the ticket, clean installs have nothing).
struct LegacyDashboardState: Equatable {
    var connection: HermesConnection?
    var credentials: DashboardCredentials?
    var cookieMirror: Data?
    var cloudflare: CloudflareAccessKeychainRecord?
    var rememberedDashboardURL: String?

    /// Whether anything at all was stored under the legacy layout.
    var isEmpty: Bool {
        connection == nil && credentials == nil && cookieMirror == nil && cloudflare == nil
    }

    /// An address identified by the old connection ticket and/or password.
    /// If both exist they must agree; the remembered URL and Cloudflare token
    /// cannot resolve a conflict between them.
    var independentDashboardURL: String? {
        let rawCandidates = [credentials?.baseURL, connection?.baseUrl].compactMap { $0 }
        guard !rawCandidates.isEmpty else { return nil }
        let candidates = rawCandidates.compactMap { try? ConnectionURLPolicy.normalizedBaseURL($0) }
        guard candidates.count == rawCandidates.count, Set(candidates).count == 1 else { return nil }
        return candidates.first
    }

    /// A migration address may come from matching connection/password state,
    /// or from an explicitly origin-bound Cloudflare record by itself. An
    /// originless token and the remembered UI URL never establish ownership.
    var derivedDashboardURL: String? {
        if connection != nil || credentials != nil { return independentDashboardURL }
        guard let origin = cloudflare?.origin,
              !origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? ConnectionURLPolicy.normalizedBaseURL(origin)
    }

    /// Cloudflare can be copied only when its explicit origin matches the
    /// target, or its originless legacy form accompanies an independent
    /// connection/password address. A conflict makes it unowned.
    func cloudflareCanBind(to dashboardURL: String) -> Bool {
        guard let cloudflare else { return false }
        let origin = cloudflare.origin.trimmingCharacters(in: .whitespacesAndNewlines)
        if origin.isEmpty {
            return independentDashboardURL == dashboardURL
        }
        guard (try? ConnectionURLPolicy.normalizedBaseURL(origin)) == dashboardURL else { return false }
        if connection != nil || credentials != nil {
            return independentDashboardURL == dashboardURL
        }
        return true
    }
}

enum SavedDashboardMigration {
    /// The exact writes a migration performs, in order. Scoped records are
    /// written FIRST, the registry LAST, and legacy records are retired only
    /// after the complete new state is committed — at every crash point the
    /// old state still works and the next launch retries (or, once the
    /// registry exists, lazily finishes the retirement).
    struct Plan: Equatable {
        var dashboardID: UUID
        var normalizedURL: String
        var label: String
        var writesConnection: Bool
        var writesCredentials: Bool
        var writesCookies: Bool
        var writesCloudflare: Bool
        /// True when the legacy chat-resume server identity (a URL) should be
        /// relabeled to the dashboard UUID so the upgrade does not trigger a
        /// one-time runtime teardown.
        var relabelsServerIdentity: Bool
        var createsRegistry: Bool
        var retiresLegacy: Bool

        static let none = Plan(
            dashboardID: UUID(),
            normalizedURL: "",
            label: "",
            writesConnection: false,
            writesCredentials: false,
            writesCookies: false,
            writesCloudflare: false,
            relabelsServerIdentity: false,
            createsRegistry: false,
            retiresLegacy: false
        )
    }

    enum Outcome: Equatable {
        /// A registry already existed: nothing to do (legacy leftovers are
        /// retired lazily).
        case alreadyMigrated(retireLegacy: Bool)
        /// No legacy state at all: commit an empty registry so clean installs
        /// never re-run migration.
        case cleanInstall
        /// There is legacy data, but no trustworthy address to attach it to.
        /// Keep it intact; a later launch may have enough state to migrate it.
        case preserveLegacy
        case migrated(Plan)
    }

    /// Pure decision function. `existingRegistry` nil means "no registry yet".
    /// `legacy` carries the current global-record state; `storedServerIdentity`
    /// is the raw chat-resume identity key value (URL-shaped in legacy
    /// builds, UUID-shaped after a relabel).
    static func outcome(
        legacy: LegacyDashboardState,
        existingRegistry: SavedDashboardRegistry?,
        storedServerIdentity: String?,
        normalizedLegacyURL: String?
    ) -> Outcome {
        if existingRegistry != nil {
            // Registry present: migration already committed. The only work
            // left is retiring whatever legacy records still exist.
            return .alreadyMigrated(retireLegacy: !legacy.isEmpty)
        }
        guard !legacy.isEmpty else { return .cleanInstall }
        guard let rawURL = legacy.derivedDashboardURL else { return .preserveLegacy }
        let normalized = normalizedLegacyURL
            ?? (try? ConnectionURLPolicy.normalizedBaseURL(rawURL))
            ?? rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = SavedDashboardLabel.derive(from: normalized)
        // Relabel the server identity only when it currently names THIS
        // address (the common upgrade path). A stored identity for a
        // different URL means the user last used another server; leave it —
        // the next connection boundary handles the switch.
        let identityMatchesURL = storedServerIdentity
            .flatMap(AppState.normalizedChatResumeServerIdentity) == normalized
            || storedServerIdentity?.trimmingCharacters(in: .whitespacesAndNewlines) == normalized
        return .migrated(Plan(
            dashboardID: UUID(),
            normalizedURL: normalized,
            label: label,
            writesConnection: legacy.connection != nil,
            writesCredentials: legacy.credentials != nil,
            writesCookies: legacy.cookieMirror != nil && legacy.independentDashboardURL == normalized,
            writesCloudflare: legacy.cloudflareCanBind(to: normalized),
            relabelsServerIdentity: identityMatchesURL,
            createsRegistry: true,
            retiresLegacy: true
        ))
    }
}

// MARK: - Orchestrator

@MainActor
enum SavedDashboardMigrator {
    /// Loads the registry, running the legacy migration when no registry
    /// exists yet. Called once per launch, before AppState hydrates its
    /// connection. Idempotent, retryable, and crash-safe by construction:
    /// see `SavedDashboardMigration.outcome`.
    static func loadRegistry(defaults: UserDefaults = .standard) -> SavedDashboardRegistry {
        let storedRegistryData = KeychainHelper.loadDashboardRegistryData()
        // An empty registry beside an old password is an upgrade that ran on
        // a locked phone with only that password saved, which it couldn't
        // read: migrate again now that it can.
        if let storedRegistryData {
            // A corrupt or newer registry is not the same as an absent one.
            // Do not replace it with a newly inferred one or retire records
            // that may be the only usable copy of a dashboard session.
            if let existing = SavedDashboardRegistryStore.load() {
                if !(existing.dashboards.isEmpty && KeychainHelper.loadCredentials() != nil) {
                    // A valid current-schema registry already owns its UUIDs,
                    // selected dashboard and scoped records. Recover a global
                    // leftover only when its own address identifies an entry
                    // and its scoped copy can be read back before cleanup.
                    recoverLegacyLeftovers(
                        LegacyDashboardReader.read(defaults: defaults),
                        into: existing
                    )
                    return existing
                }
                // An empty registry beside a readable legacy password is a
                // retry after an earlier locked launch.
            } else {
                return SavedDashboardRegistry()
            }
        }
        let legacy = LegacyDashboardReader.read(defaults: defaults)
        let outcome = SavedDashboardMigration.outcome(
            legacy: legacy,
            existingRegistry: nil,
            storedServerIdentity: defaults.string(forKey: AppState.chatResumeServerIdentityKey),
            normalizedLegacyURL: nil
        )
        switch outcome {
        case .alreadyMigrated:
            // This outcome belongs to a caller with an existing registry. If
            // reached without one, leave all records available for a retry.
            return SavedDashboardRegistry()
        case .cleanInstall:
            let registry = SavedDashboardRegistry()
            _ = SavedDashboardRegistryStore.save(registry)
            return registry
        case .preserveLegacy:
            return SavedDashboardRegistry()
        case .migrated(let plan):
            return execute(plan: plan, legacy: legacy, defaults: defaults) ?? SavedDashboardRegistry()
        }
    }

    /// Applies a migration plan. Ordering is load-bearing: every dashboard-
    /// scoped secure record is written before the registry commits, and the
    /// legacy records are deleted only after the registry is durable.
    static func execute(
        plan: SavedDashboardMigration.Plan,
        legacy: LegacyDashboardState,
        defaults: UserDefaults
    ) -> SavedDashboardRegistry? {
        let dashboard = SavedDashboard(
            id: plan.dashboardID,
            label: plan.label,
            normalizedURL: plan.normalizedURL
        )
        let registry = SavedDashboardRegistry(
            activeDashboardID: plan.dashboardID,
            dashboards: [dashboard]
        )

        guard legacy.derivedDashboardURL == plan.normalizedURL else { return nil }

        if let connection = legacy.connection, plan.writesConnection {
            guard Self.normalized(connection.baseUrl) == plan.normalizedURL else { return nil }
            KeychainHelper.saveConnection(connection, dashboardID: plan.dashboardID)
            guard KeychainHelper.loadConnection(dashboardID: plan.dashboardID) == connection else { return nil }
        }
        if let credentials = legacy.credentials, plan.writesCredentials {
            guard Self.normalized(credentials.baseURL) == plan.normalizedURL else { return nil }
            KeychainHelper.saveCredentials(credentials, dashboardID: plan.dashboardID)
            guard KeychainHelper.loadCredentials(dashboardID: plan.dashboardID) == credentials else { return nil }
        }
        if let cookies = legacy.cookieMirror, plan.writesCookies {
            // Cookie mirrors carry no address themselves. Only migrate them
            // alongside a ticket or password record that identifies this URL.
            guard legacy.independentDashboardURL == plan.normalizedURL else { return nil }
            KeychainHelper.saveDashboardCookies(cookies, dashboardID: plan.dashboardID)
            guard KeychainHelper.loadDashboardCookies(dashboardID: plan.dashboardID) == cookies else { return nil }
        }
        if let cloudflare = legacy.cloudflare, plan.writesCloudflare {
            // A pre-origin record can be bound only when a credential or
            // connection independently identifies this sole legacy target.
            guard legacy.cloudflareCanBind(to: plan.normalizedURL) else { return nil }
            let migratedCloudflare = cloudflare.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? CloudflareAccessKeychainRecord(
                    clientID: cloudflare.clientID,
                    clientSecret: cloudflare.clientSecret,
                    origin: plan.normalizedURL
                ) : cloudflare
            KeychainHelper.saveCloudflareKeychainRecord(migratedCloudflare, dashboardID: plan.dashboardID)
            guard KeychainHelper.loadCloudflareKeychainRecord(dashboardID: plan.dashboardID) == migratedCloudflare else {
                return nil
            }
        }
        // The registry is the commit marker. Never retire the old records,
        // or relabel their runtime identity, until every scoped write and
        // the registry itself can be read back.
        guard SavedDashboardRegistryStore.save(registry) else { return nil }
        if plan.relabelsServerIdentity {
            defaults.set(plan.dashboardID.uuidString, forKey: AppState.chatResumeServerIdentityKey)
        }
        if plan.retiresLegacy {
            recoverLegacyLeftovers(legacy, into: registry)
        }
        return registry
    }

    private static func normalized(_ value: String) -> String {
        (try? ConnectionURLPolicy.normalizedBaseURL(value)) ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Completes a migration interrupted after a registry commit, or removes
    /// duplicate global records after a new commit. Every record is assigned
    /// by its own address, never by whichever dashboard happens to be active.
    private static func recoverLegacyLeftovers(
        _ legacy: LegacyDashboardState,
        into registry: SavedDashboardRegistry
    ) {
        // A disagreeing ticket/password pair has no safe owner. Keep all
        // leftovers until the user reconnects and supplies an unambiguous URL.
        guard let ownerURL = legacy.derivedDashboardURL,
              let id = registry.dashboardID(atNormalizedURL: normalized(ownerURL)),
              let dashboard = registry.dashboard(with: id) else { return }

        let connectionIsScoped = legacy.connection.map { connection in
            normalized(connection.baseUrl) == ownerURL && ensureScopedCopy(
                connection,
                load: { KeychainHelper.loadConnection(dashboardID: $0) },
                save: { KeychainHelper.saveConnection($0, dashboardID: id) },
                dashboardID: id,
                accepts: { normalized($0.baseUrl) == ownerURL }
            )
        } ?? true

        // A known dashboard's own password wins over a stale global copy.
        let credentialsAreScoped = legacy.credentials.map { credentials in
            normalized(credentials.baseURL) == ownerURL && ensureScopedCopy(
                credentials,
                load: { KeychainHelper.loadCredentials(dashboardID: $0) },
                save: { KeychainHelper.saveCredentials($0, dashboardID: id) },
                dashboardID: id,
                accepts: { normalized($0.baseURL) == ownerURL }
            )
        } ?? true

        // Addressless dependents must become durable before their old address
        // evidence is retired. Failed writes remain retryable next launch.
        let cookiesAreScoped = legacy.cookieMirror.map { cookies in
            legacy.independentDashboardURL == ownerURL && ensureScopedCopy(
                cookies,
                load: { KeychainHelper.loadDashboardCookies(dashboardID: $0) },
                save: { KeychainHelper.saveDashboardCookies($0, dashboardID: id) },
                dashboardID: id,
                accepts: { $0 == cookies }
            )
        } ?? true
        if cookiesAreScoped, legacy.cookieMirror != nil {
            KeychainHelper.clearLegacyDashboardCookies()
        }

        var originlessCloudflareIsScoped = legacy.cloudflare.map {
            !$0.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? true
        if let cloudflare = legacy.cloudflare, legacy.cloudflareCanBind(to: ownerURL) {
            let isOriginless = cloudflare.origin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let scoped = isOriginless
                ? CloudflareAccessKeychainRecord(
                    clientID: cloudflare.clientID,
                    clientSecret: cloudflare.clientSecret,
                    origin: dashboard.normalizedURL
                )
                : cloudflare
            let cloudflareIsScoped = ensureScopedCopy(
                scoped,
                load: { KeychainHelper.loadCloudflareKeychainRecord(dashboardID: $0) },
                save: { KeychainHelper.saveCloudflareKeychainRecord($0, dashboardID: id) },
                dashboardID: id,
                accepts: { $0 == scoped }
            )
            if cloudflareIsScoped { KeychainHelper.clearCloudflareAccess() }
            if isOriginless { originlessCloudflareIsScoped = cloudflareIsScoped }
        }

        let addresslessDependentsAreScoped = cookiesAreScoped && originlessCloudflareIsScoped
        if addresslessDependentsAreScoped {
            if connectionIsScoped, legacy.connection != nil { KeychainHelper.clearLegacyConnectionTicket() }
            if credentialsAreScoped, legacy.credentials != nil { KeychainHelper.clearCredentials() }
        }
    }

    private static func ensureScopedCopy<Value>(
        _ value: Value,
        load: (UUID) -> Value?,
        save: (Value) -> Void,
        dashboardID: UUID,
        accepts: (Value) -> Bool
    ) -> Bool {
        if let existing = load(dashboardID) { return accepts(existing) }
        save(value)
        guard let stored = load(dashboardID) else { return false }
        return accepts(stored)
    }

    /// Unlock retry uses exactly the same address, ownership and readback
    /// checks as launch-time recovery.
    static func recoverLegacyLeftovers(into registry: SavedDashboardRegistry, defaults: UserDefaults) {
        recoverLegacyLeftovers(LegacyDashboardReader.read(defaults: defaults), into: registry)
    }

}

/// Reads and retires the legacy global auth records. Kept separate from the
/// KeychainHelper scoped APIs so the multi-server paths can never accidentally
/// reach for global state: only migration and lazy cleanup touch these.
enum LegacyDashboardReader {
    static func read(defaults: UserDefaults) -> LegacyDashboardState {
        LegacyDashboardState(
            connection: KeychainHelper.loadConnection(),
            credentials: KeychainHelper.loadCredentials(),
            cookieMirror: KeychainHelper.loadDashboardCookies(),
            cloudflare: KeychainHelper.loadCloudflareKeychainRecord(),
            rememberedDashboardURL: defaults.string(forKey: "conduit.dashboardURL")
        )
    }

    /// Deletes the legacy global records. The installation-wide push
    /// registration is deliberately untouched: push pairing is per-device,
    /// not per-dashboard.
    static func retireLegacy(keepingCredentials: Bool = false) {
        KeychainHelper.clearConnection()
        if !keepingCredentials {
            KeychainHelper.clearCredentials()
        }
        KeychainHelper.clearCloudflareAccess()
    }
}
