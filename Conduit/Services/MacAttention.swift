//
//  MacAttention.swift
//  Conduit
//
//  Conduit for Mac (scripts/mac-catalyst-build.sh) has no relay pushes and
//  no Live Activities: signed to run locally, it has no push entitlement.
//  So while it runs it posts its own notifications for what the relay would
//  have pushed (a reply ready, a turn that failed, Hermes waiting for an
//  approval or an answer, a background task done), and keeps a Dock badge
//  of the chats that are unread or waiting on the user.
//
//  It hears every chat's stream events on this Mac's socket (the open chat,
//  and the chats it sent and left), and the live registry's snapshots for a
//  chat run elsewhere that starts waiting on the user (a reply there is the
//  other device's to announce). Like the relay while Conduit is in front on
//  an iPhone, it stays quiet while Conduit is the app in front with its
//  window showing. The words are the relay's (NotificationCopy), at the
//  detail Settings > Notifications keeps (Generic by default).
//
//  Not covered yet: with the window hidden or minimized Conduit stops
//  reading the registry and doesn't reconnect a socket that dropped, so
//  only chats on a live socket notify then.
//

#if targetEnvironment(macCatalyst)
import Combine
import Foundation
import os
import UIKit
import UserNotifications

/// What to notify and when, without UIKit or the notification center.
struct MacAttentionPolicy {
    enum Kind: String, CaseIterable {
        case responseReady = "response.ready"
        case turnFailed = "turn.failed"
        case approvalNeeded = "approval.needed"
        case inputNeeded = "input.needed"
        case backgroundTaskFinished = "background_task.finished"

        /// Kinds that stand for the same moment, so the stream and the
        /// registry reporting it never give two notifications.
        var group: String {
            switch self {
            case .responseReady, .turnFailed: return "done"
            case .approvalNeeded, .inputNeeded: return "waiting"
            case .backgroundTaskFinished: return "task"
            }
        }

        var waitsOnUser: Bool { group == "waiting" }
    }

    /// What a stream event asks to notify, with the request it answers.
    enum StreamSignal: Equatable {
        case notify(Kind, requestID: String?)
        /// A reply finished: notify once the chat stays quiet.
        case replyFinished
        /// The chat is working: a reply waiting to be announced isn't the
        /// turn's last, and a later reply is news again.
        case activity
    }

    /// The longest Full previews body, as for a notification Hermes writes
    /// itself (conduit_notify).
    static let previewLength = 300

    /// The same chat and moment within this long is one notification.
    static let repeatWindow: TimeInterval = 90
    /// How long a finished reply waits for more of the turn.
    static let replySettle: TimeInterval = 4
    static let maxRememberedRequests = 200

    private struct Notified {
        var at: Date
        /// Notified for a request of its own (an approval, a question),
        /// rather than a report that only says the chat waits.
        var byRequest: Bool
    }

    private var notified: [String: Notified] = [:]
    private var notifiedRequests: [String] = []
    /// Each dashboard and profile's live registry, runtime id to status.
    private var registry: [String: [String: String]] = [:]

    static func signal(for event: StreamEvent) -> StreamSignal? {
        switch event {
        case .messageComplete(_, _, let content, _, _):
            // A turn's last reply, even one already shown as it streamed;
            // only Hermes' note that the user interrupted it isn't news.
            if let content, MessageNormalizer.isUserCorrectionInterruptionNotice(content) { return nil }
            return .replyFinished
        case .messageError:
            return .notify(.turnFailed, requestID: nil)
        case .approval(_, let activity):
            guard activity.status == .pending else { return nil }
            return .notify(.approvalNeeded, requestID: activity.requestId.map { "approval:\($0)" })
        case .clarify(_, let activity):
            guard !activity.isExpired else { return nil }
            return .notify(.inputNeeded, requestID: "clarify:\(activity.requestId)")
        case .inputPrompt(_, let activity):
            return .notify(.inputNeeded, requestID: "input:\(activity.requestId)")
        case .sideAgentComplete(_, let kind, let taskID, _, _):
            guard kind == .background else { return nil }
            return .notify(.backgroundTaskFinished, requestID: "task:\(taskID)")
        case .messageStart, .messageDelta, .reasoningDelta, .messageInterim, .toolStart:
            return .activity
        default:
            return nil
        }
    }

    /// The title Hermes gave a chat: not the placeholder, nor the opening
    /// message, whole or cut short, that a listing stands in with until
    /// Hermes names the chat (after its first reply).
    static func hostTitle(_ title: String, preview: String?) -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != "Untitled conversation" else { return nil }
        guard let preview = preview?.trimmingCharacters(in: .whitespacesAndNewlines), !preview.isEmpty else { return title }
        if title == preview { return nil }
        for ellipsis in ["…", "..."] where title.hasSuffix(ellipsis) {
            let start = title.dropLast(ellipsis.count).trimmingCharacters(in: .whitespaces)
            if !start.isEmpty, preview.hasPrefix(start) { return nil }
        }
        return title
    }

    /// What Hermes said with the event, for Full previews: the reply, what
    /// an approval or question asks, a task's result. As the relay's pushes,
    /// never an approval's command, a failure's error or a password or
    /// secret prompt, which can carry what shouldn't be on screen.
    static func previewText(for event: StreamEvent) -> String? {
        switch event {
        case .messageComplete(_, _, let content, _, _): return content
        case .approval(_, let activity): return activity.description
        case .clarify(_, let activity): return activity.questions.first?.question
        case .sideAgentComplete(_, _, _, let text, _): return text
        default: return nil
        }
    }

    /// A preview's body: one line as a chat row reads it, without a file's
    /// path, up to `previewLength`.
    static func previewBody(_ text: String) -> String? {
        let line = PreviewText.plain(GatewayMediaTags.removingTags(from: text))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > previewLength ? String(line.prefix(previewLength - 1)) + "…" : line
    }

    /// Whether to notify `kind` for the chat known by `keys` (any of its
    /// ids). Records it when it does.
    ///
    /// A request (an approval, a question) is news once, whenever it comes;
    /// a report without one (a reply, a failure, the registry saying a chat
    /// waits) is news unless the chat's same moment was told within the
    /// repeat window, by any of its ids.
    mutating func admit(_ kind: Kind, keys: [String], requestID: String?, now: Date = Date()) -> Bool {
        let groupKeys = keys.filter { !$0.isEmpty }.map { "\(kind.group)|\($0)" }
        guard !groupKeys.isEmpty else { return false }
        notified = notified.filter { now.timeIntervalSince($0.value.at) < Self.repeatWindow }
        let recent = groupKeys.compactMap { notified[$0] }.max { $0.at < $1.at }
        if let requestID {
            guard !notifiedRequests.contains(requestID) else { return false }
            notifiedRequests.append(requestID)
            if notifiedRequests.count > Self.maxRememberedRequests {
                notifiedRequests.removeFirst(notifiedRequests.count - Self.maxRememberedRequests)
            }
            // The registry already said this chat waits: the same moment.
            if let recent, !recent.byRequest {
                record(groupKeys, Notified(at: recent.at, byRequest: true))
                return false
            }
            record(groupKeys, Notified(at: now, byRequest: true))
            return true
        }
        if let recent {
            // The same moment by another of the chat's ids: remember those
            // ids too, so a third report by any of them is the same one.
            record(groupKeys, recent)
            return false
        }
        record(groupKeys, Notified(at: now, byRequest: false))
        return true
    }

    /// The chat is working again: its next reply or failure is news.
    mutating func turnContinues(keys: [String]) {
        for key in keys where !key.isEmpty { notified["done|\(key)"] = nil }
    }

    private mutating func record(_ keys: [String], _ entry: Notified) {
        for key in keys { notified[key] = entry }
    }

    /// The chats a registry snapshot says began to wait on the user. The
    /// first snapshot of a dashboard's profile only records where things
    /// stand.
    mutating func newlyWaiting(_ rows: [LiveSessionStatus], scope: String) -> [LiveSessionStatus] {
        let previous = registry[scope]
        var next: [String: String] = [:]
        var waiting: [LiveSessionStatus] = []
        for row in rows {
            next[row.runtimeSessionId] = row.status
            if let previous, row.status == "waiting", previous[row.runtimeSessionId] != "waiting" {
                waiting.append(row)
            }
        }
        registry[scope] = next
        return waiting
    }

    /// After a disconnect a snapshot is a fresh start, not news.
    mutating func forgetRegistry() {
        registry = [:]
    }

    /// The Dock badge: the chats the Chats list shows as unread or waiting
    /// on the user, each counted once.
    static func badgeCount<Row>(_ rows: [Row], key: (Row) -> String, needsUser: (Row) -> Bool) -> Int {
        Set(rows.filter(needsUser).map(key)).count
    }
}

/// Posts Conduit for Mac's notifications and keeps its Dock badge.
@MainActor
final class MacAttention {
    static let shared = MacAttention()
    static let identifierPrefix = "conduit-mac-"
    static let userInfoKey = "conduit_mac"

    private static let log = Logger(subsystem: "com.milim.relay", category: "mac-attention")

    private weak var appState: AppState?
    private let center = UNUserNotificationCenter.current()
    private var policy = MacAttentionPolicy()
    private var pendingReplies: [String: Task<Void, Never>] = [:]
    private var observers: [NSObjectProtocol] = []
    private var badgeUpdates: AnyCancellable?
    private var connection: AnyCancellable?
    private var shownBadge: Int?
    private var askedForPermission = false
    /// Each live chat's stored id by the runtime id its stream events carry,
    /// from the registry's snapshots: the Chats list knows a chat by its
    /// stored id.
    private var storedIDs: [String: String] = [:]

    func start(appState: AppState) {
        guard self.appState == nil else { return }
        self.appState = appState
        let notifications = NotificationCenter.default
        observers = [
            // AppKit's: UIKit doesn't reliably report a Mac's app switch.
            notifications.addObserver(forName: Notification.Name("NSApplicationDidBecomeActiveNotification"), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // Badges may have been turned on in System Settings.
                    MacAttention.shared.shownBadge = nil
                    MacAttention.shared.updateBadge()
                }
            },
            // A badge left on a closed app's Dock icon would go stale.
            notifications.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MacAttention.shared.setBadge(0) }
            },
        ]
        connection = appState.$isConnected
            .removeDuplicates()
            .sink { connected in
                Task { @MainActor in
                    guard connected else {
                        MacAttention.shared.policy.forgetRegistry()
                        return
                    }
                    // The first connection asks once for alerts, sounds and
                    // the badge.
                    await MacAttention.shared.askForPermissionOnce()
                }
            }
        let changes: [AnyPublisher<Void, Never>] = [
            appState.$sessions.map { _ in () }.eraseToAnyPublisher(),
            appState.$cronSessions.map { _ in () }.eraseToAnyPublisher(),
            appState.$chatReadState.map { _ in () }.eraseToAnyPublisher(),
            appState.$liveSessionStatusIndex.map { _ in () }.eraseToAnyPublisher(),
            appState.$liveSessionStatusAvailable.map { _ in () }.eraseToAnyPublisher(),
            appState.$allProfilesCatalog.map { _ in () }.eraseToAnyPublisher(),
            appState.$activeProfile.map { _ in () }.eraseToAnyPublisher(),
            appState.$pinnedSessionIDs.map { _ in () }.eraseToAnyPublisher(),
            appState.$isConnected.map { _ in () }.eraseToAnyPublisher(),
        ]
        // Published values change in willSet: count after they land, and
        // not at streaming rate.
        badgeUpdates = Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { _ in MainActor.assumeIsolated { MacAttention.shared.updateBadge() } }
    }

    /// Conduit is the app in front. UIKit doesn't say on a Mac: its app
    /// state and the window's scene stay active while another app is in
    /// front. AppKit's NSApplication does, so it's asked each time.
    private var isFrontmost: Bool {
        let isActive = NSSelectorFromString("isActive")
        guard let appKit = NSClassFromString("NSApplication") as? NSObject.Type,
              let app = appKit.value(forKey: "sharedApplication") as? NSObject,
              app.responds(to: isActive) else {
            return UIApplication.shared.applicationState == .active
        }
        return (app.value(forKey: "active") as? Bool) ?? true
    }

    // MARK: Events

    /// Every stream event on this Mac's socket, for any chat.
    func streamEvent(_ event: StreamEvent, sessionID: String) {
        guard let signal = MacAttentionPolicy.signal(for: event) else { return }
        guard !sessionID.isEmpty, let appState else {
            Self.log.debug("Signal dropped: no chat id or app state")
            return
        }
        Self.log.debug("Signal \(String(describing: signal), privacy: .public) frontmost=\(self.isFrontmost, privacy: .public) sceneActive=\(appState.isSceneActive, privacy: .public)")
        switch signal {
        case .activity:
            pendingReplies.removeValue(forKey: sessionID)?.cancel()
            let ids = chatIDs(sessionID)
            policy.turnContinues(keys: keys(for: ids, row: catalogRow(for: ids, in: appState)))
        case .replyFinished:
            pendingReplies.removeValue(forKey: sessionID)?.cancel()
            // Watched as it landed, in Conduit: not news afterwards either.
            guard !(isFrontmost && appState.isSceneActive) else { return }
            // A follow-up Hermes took on its own stays quiet, as its push does.
            if let followUp = appState.predictiveFollowUpTurn?.sessionID,
               keys(for: chatIDs(sessionID), row: catalogRow(for: chatIDs(sessionID), in: appState)).contains(followUp) {
                Self.log.debug("Reply skipped: predictive follow-up")
                return
            }
            let reply = MacAttentionPolicy.previewText(for: event)
            pendingReplies[sessionID] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(MacAttentionPolicy.replySettle))
                guard !Task.isCancelled else { return }
                Self.log.debug("Reply settled")
                MacAttention.shared.pendingReplies[sessionID] = nil
                MacAttention.shared.notify(.responseReady, ids: MacAttention.shared.chatIDs(sessionID), requestID: nil, text: reply)
            }
        case .notify(let kind, let requestID):
            if kind == .turnFailed { pendingReplies.removeValue(forKey: sessionID)?.cancel() }
            notify(kind, ids: chatIDs(sessionID), requestID: requestID, text: MacAttentionPolicy.previewText(for: event))
        }
    }

    /// A live registry snapshot of `profile`: a chat run elsewhere that
    /// began to wait on the user. Which decision it waits on, the registry
    /// doesn't say.
    func registrySnapshot(_ rows: [LiveSessionStatus], profile: String) {
        guard let appState else { return }
        let scope = "\(appState.activeDashboardID?.uuidString ?? "none")|\(profile)"
        if storedIDs.count > 1_000 { storedIDs = [:] }
        for row in rows where !row.runtimeSessionId.isEmpty && !row.storedSessionId.isEmpty {
            storedIDs[row.runtimeSessionId] = row.storedSessionId
        }
        for row in policy.newlyWaiting(rows, scope: scope) {
            notify(.inputNeeded, ids: [row.runtimeSessionId, row.storedSessionId], requestID: nil, requiresListedChat: true)
        }
    }

    // MARK: Notifications

    /// `text` is what Hermes said with it, shown only with Full previews.
    private func notify(_ kind: MacAttentionPolicy.Kind, ids: [String], requestID: String?, text: String? = nil, requiresListedChat: Bool = false) {
        guard let appState else { return }
        // In front with the window showing: the chats list and the open
        // chat already show it, as an iPhone keeps the relay quiet.
        guard !isFrontmost || !appState.isSceneActive else { return skip(kind, "in front") }
        guard wanted(kind) else { return skip(kind, "turned off") }
        let row = catalogRow(for: ids, in: appState)
        // Without its row a registry report can't say whose chat it is.
        if requiresListedChat, row == nil { return skip(kind, "chat not listed") }
        if let row, appState.isPulseHomeChat(row) { return skip(kind, "Pulse home chat") }
        // A call speaks each reply.
        if kind == .responseReady, appState.isVoiceCallInProgress { return skip(kind, "voice call") }
        guard policy.admit(kind, keys: keys(for: ids, row: row), requestID: requestID) else { return skip(kind, "already told") }

        let chatKey = row.map(ChatReadState.durableID(for:)) ?? ids.first ?? ""
        let profileID = row.map(appState.rowProfile) ?? appState.activeProfile
        let dashboardID = appState.activeDashboardID?.uuidString
        let generic = NotificationCopy.generic(for: kind.rawValue)

        let content = UNMutableNotificationContent()
        content.title = generic.title
        content.body = generic.body
        let detail = PushNotificationService.shared.preferences.detail
        if detail != .generic {
            // The chat's title and its bot, by the names Conduit shows; with
            // Full previews, Hermes' words too.
            var described: [String: Any] = [
                "title_label": kind.rawValue,
                "profile": profileID,
                "profile_name": appState.profileDisplayName(profileID),
            ]
            if let title = row.flatMap(Self.hostTitle) { described["session_title"] = title }
            if detail == .previews, let body = text.flatMap(MacAttentionPolicy.previewBody) { described["body"] = body }
            let named = NotificationCopy.named(described, mainName: NotificationCopy.mainName(
                dashboardID: dashboardID,
                activeDashboardID: dashboardID,
                names: NotificationSharedSettings.mainProfileNames
            ))
            let shown: (title: String?, subtitle: String?, body: String?)
            if detail == .previews {
                shown = NotificationCopy.preview(named)
            } else {
                let names = NotificationCopy.chatNames(named)
                shown = (names.title, names.subtitle, nil)
            }
            if let title = shown.title { content.title = title }
            if let subtitle = shown.subtitle { content.subtitle = subtitle }
            if let body = shown.body { content.body = body }
        }
        content.threadIdentifier = chatKey
        let preferences = PushNotificationService.shared.preferences
        if kind.waitsOnUser ? preferences.attentionSound : preferences.completionSound {
            content.sound = .default
        }
        var target: [String: Any] = ["session_id": ids.first ?? chatKey, "profile": profileID, "type": kind.rawValue]
        if let durable = row?.storedSessionId ?? row.map(ChatReadState.durableID(for:)) ?? ids.dropFirst().first(where: { !$0.isEmpty }) {
            target["stored_session_id"] = durable
        }
        if let dashboardID { target["dashboard_id"] = dashboardID }
        content.userInfo = [Self.userInfoKey: target]

        // A newer notification for the chat replaces its older one.
        let request = UNNotificationRequest(
            identifier: "\(Self.identifierPrefix)\(kind.group)-\(chatKey)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                Self.log.error("Notification not posted: \(String(describing: type(of: error)), privacy: .public)")
            } else {
                Self.log.debug("Posted \(kind.rawValue, privacy: .public)")
            }
        }
    }

    private func skip(_ kind: MacAttentionPolicy.Kind, _ reason: String) {
        Self.log.debug("Not posted \(kind.rawValue, privacy: .public): \(reason, privacy: .public)")
    }

    private static func hostTitle(_ row: SessionSummary) -> String? {
        MacAttentionPolicy.hostTitle(row.title, preview: row.preview)
    }

    private func wanted(_ kind: MacAttentionPolicy.Kind) -> Bool {
        let preferences = PushNotificationService.shared.preferences
        switch kind {
        case .responseReady: return preferences.responseReady
        case .turnFailed: return preferences.turnFailed
        case .approvalNeeded: return preferences.approvalNeeded
        case .inputNeeded: return preferences.inputNeeded
        case .backgroundTaskFinished: return preferences.backgroundTaskFinished
        }
    }

    /// A chat's row in what the Chats list can show: the profile in use's,
    /// and All's other profiles.
    private func catalogRow(for ids: [String], in appState: AppState) -> SessionSummary? {
        let wanted = Set(ids.filter { !$0.isEmpty })
        guard !wanted.isEmpty else { return nil }
        let others = appState.allProfilesCatalog.dashboardID == appState.activeDashboardID ? appState.allProfilesCatalog.sessions : []
        return (appState.sessions + appState.cronSessions + others).first { row in
            wanted.contains(row.id) || row.storedSessionId.map(wanted.contains) == true
                || !wanted.isDisjoint(with: row.alternateIds)
        }
    }

    /// A stream event's chat by every id it is known under.
    private func chatIDs(_ sessionID: String) -> [String] {
        [sessionID] + (storedIDs[sessionID].map { [$0] } ?? [])
    }

    private func keys(for ids: [String], row: SessionSummary?) -> [String] {
        ids + (row.map { [$0.id, $0.storedSessionId ?? "", ChatReadState.durableID(for: $0)] } ?? [])
    }

    /// The chat a tapped notification opens: only one Conduit posted.
    nonisolated static func target(from request: UNNotificationRequest) -> ConduitNotificationTarget? {
        guard request.identifier.hasPrefix(identifierPrefix), !(request.trigger is UNPushNotificationTrigger),
              let payload = request.content.userInfo[userInfoKey] as? [String: Any],
              let sessionID = payload["session_id"] as? String, !sessionID.isEmpty else { return nil }
        let dashboardID = (payload["dashboard_id"] as? String).flatMap(UUID.init(uuidString:))
        return ConduitNotificationTarget(
            profile: payload["profile"] as? String,
            sessionId: sessionID,
            durableSessionID: payload["stored_session_id"] as? String,
            dashboardID: dashboardID,
            type: payload["type"] as? String
        )
    }

    // MARK: Permission and badge

    private func askForPermissionOnce() async {
        guard !askedForPermission else { return }
        askedForPermission = true
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            } catch {
                Self.log.error("Notification permission not asked: \(String(describing: type(of: error)), privacy: .public)")
            }
        } else if settings.badgeSetting != .enabled {
            Self.log.info("Dock badge is off for Conduit in System Settings")
        }
        await PushNotificationService.shared.refresh()
        // A badge set before the answer didn't show.
        shownBadge = nil
        updateBadge()
    }

    private func updateBadge() {
        guard let appState else { return }
        guard appState.isConnected else { return setBadge(0) }
        let rows = appState.chatListSessions.filter { !$0.isArchived && !appState.isPulseHomeChat($0) }
            + appState.chatListCronSessions.filter { !$0.isArchived && appState.isSessionPinned($0) }
        let waiting = appState.liveSessionStatusAvailable
        setBadge(MacAttentionPolicy.badgeCount(
            rows,
            key: { appState.rowProfile($0) + "\u{1F}" + ChatReadState.durableID(for: $0) },
            needsUser: { appState.isSessionUnread($0) || (waiting && appState.sessionLiveStatus($0) == .needsInput) }
        ))
    }

    private func setBadge(_ count: Int) {
        guard count != shownBadge else { return }
        shownBadge = count
        center.setBadgeCount(count) { error in
            guard let error else { return }
            Self.log.error("Badge not set: \(String(describing: type(of: error)), privacy: .public)")
            // Try again on the next change.
            Task { @MainActor in MacAttention.shared.shownBadge = nil }
        }
    }
}
#endif
