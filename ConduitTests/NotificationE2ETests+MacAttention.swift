//
//  NotificationE2ETests+MacAttention.swift
//  Conduit
//
//  Conduit for Mac's own notifications and Dock badge (MacAttention.swift):
//  which events notify, one notification per chat and moment, the live
//  registry's changes, and a tapped notification's chat. Written as an
//  extension of an existing suite: the CI test planner finds classes in the
//  sources, and these exist only in the Mac build.
//

#if targetEnvironment(macCatalyst)
import Foundation
import UserNotifications
import XCTest
@testable import Conduit

extension NotificationE2ETests {
    private func approval(_ status: ApprovalActivity.Status, requestID: String? = "a1") -> StreamEvent {
        var activity = ApprovalActivity(
            sessionId: "s1",
            command: "run tests",
            description: "wants to run tests",
            choices: nil,
            allowPermanent: false,
            smartDenied: false,
            status: status,
            choice: nil,
            error: nil
        )
        activity.requestId = requestID
        return .approval(sessionId: "s1", activity: activity)
    }

    func testMacAttentionNotifiesWhatTheRelayWouldPush() {
        typealias Policy = MacAttentionPolicy
        XCTAssertEqual(Policy.signal(for: .messageComplete(sessionId: "s1", messageId: "m", content: "hi", reasoning: nil, alreadyShown: false)), .replyFinished)
        XCTAssertEqual(Policy.signal(for: .messageComplete(sessionId: "s1", messageId: "m", content: "hi", reasoning: nil, alreadyShown: true)),
                       .replyFinished, "a reply shown as it streamed still ends the turn")
        XCTAssertEqual(Policy.signal(for: .messageError(sessionId: "s1", message: "boom")), .notify(.turnFailed, requestID: nil))
        XCTAssertEqual(Policy.signal(for: approval(.pending)), .notify(.approvalNeeded, requestID: "approval:a1"))
        XCTAssertNil(Policy.signal(for: approval(.approved)), "an answered approval waits on nobody")
        let question = ClarifyActivity(requestId: "q1", question: "Continue?", choices: [], status: .pending)
        XCTAssertEqual(Policy.signal(for: .clarify(sessionId: "s1", activity: question)), .notify(.inputNeeded, requestID: "clarify:q1"))
        XCTAssertEqual(Policy.signal(for: .sideAgentComplete(sessionId: "s1", kind: .background, taskId: "t1", text: "done", question: nil)),
                       .notify(.backgroundTaskFinished, requestID: "task:t1"))
        XCTAssertNil(Policy.signal(for: .sideAgentComplete(sessionId: "s1", kind: .btw, taskId: "t2", text: "aside", question: "why?")))
        XCTAssertEqual(Policy.signal(for: .messageDelta(sessionId: "s1", text: "more")), .activity)
        XCTAssertEqual(Policy.signal(for: .toolStart(sessionId: "s1", toolName: "terminal", toolInput: nil, toolID: nil)), .activity)
    }

    func testMacPreviewsShowWhatHermesSaid() throws {
        typealias Policy = MacAttentionPolicy
        XCTAssertEqual(Policy.previewText(for: .messageComplete(sessionId: "s1", messageId: "m", content: "pong", reasoning: nil)), "pong")
        XCTAssertNil(Policy.previewText(for: .messageError(sessionId: "s1", message: "boom")), "a failure's error stays generic")
        XCTAssertEqual(Policy.previewText(for: approval(.pending)), "wants to run tests")
        XCTAssertEqual(Policy.previewText(for: .sideAgentComplete(sessionId: "s1", kind: .background, taskId: "t1", text: "done", question: nil)), "done")
        let secret = InputPromptActivity(requestId: "srq-1", sessionId: "s1", kind: .secret)
        XCTAssertNil(Policy.previewText(for: .inputPrompt(sessionId: "s1", activity: secret)), "a secret's prompt stays generic")

        XCTAssertEqual(Policy.previewBody("**Done.** See `notes.md`\n\nand  the rest"), "Done. See notes.md and the rest")
        XCTAssertEqual(Policy.previewBody("## Camp\n- Tent\n2. Pack\nMEDIA:/opt/data/cache/list.pdf"), "Camp Tent Pack",
                       "block marks drop and a file's path never shows")
        XCTAssertNil(Policy.previewBody(" \n "))
        let long = try XCTUnwrap(Policy.previewBody(String(repeating: "word ", count: 100)))
        XCTAssertEqual(long.count, Policy.previewLength)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testMacNotificationsNameOnlyATitleHermesGave() {
        let opening = "Title test: please run sleep 30 in the terminal first, then reply with just the word kiwi."
        XCTAssertEqual(MacAttentionPolicy.hostTitle("Run sleep 30 terminal command", preview: opening), "Run sleep 30 terminal command")
        XCTAssertNil(MacAttentionPolicy.hostTitle("Title test: please run sleep 30 in the terminal…", preview: opening),
                     "the listing's stand-in until Hermes names the chat")
        XCTAssertNil(MacAttentionPolicy.hostTitle(opening, preview: opening))
        XCTAssertNil(MacAttentionPolicy.hostTitle("Untitled conversation", preview: nil))
        XCTAssertEqual(MacAttentionPolicy.hostTitle("Trip notes…", preview: "Plan the trip"), "Trip notes…")
    }

    func testMacAttentionNotifiesAChatsMomentOnce() {
        var policy = MacAttentionPolicy()
        let now = Date()
        XCTAssertTrue(policy.admit(.responseReady, keys: ["rt-1"], requestID: nil, now: now))
        // The same reply reported by its stored id too.
        XCTAssertFalse(policy.admit(.responseReady, keys: ["rt-1", "stored-1"], requestID: nil, now: now.addingTimeInterval(5)))
        XCTAssertFalse(policy.admit(.turnFailed, keys: ["stored-1"], requestID: nil, now: now.addingTimeInterval(6)),
                       "a failure and a reply of one turn are the same moment, by any of the chat's ids")
        // The chat works again: its next reply is news.
        policy.turnContinues(keys: ["rt-1"])
        XCTAssertTrue(policy.admit(.responseReady, keys: ["rt-1"], requestID: nil, now: now.addingTimeInterval(20)))
        XCTAssertFalse(policy.admit(.responseReady, keys: ["", ""], requestID: nil, now: now), "no chat, no notification")
    }

    func testMacAttentionNotifiesEachRequestOnce() {
        var policy = MacAttentionPolicy()
        let now = Date()
        XCTAssertTrue(policy.admit(.approvalNeeded, keys: ["rt-1"], requestID: "approval:a1", now: now))
        XCTAssertFalse(policy.admit(.inputNeeded, keys: ["rt-1"], requestID: nil, now: now.addingTimeInterval(2)),
                       "the registry saying the chat waits is the same moment")
        XCTAssertTrue(policy.admit(.approvalNeeded, keys: ["rt-1"], requestID: "approval:a2", now: now.addingTimeInterval(20)),
                      "a second approval in the same chat is news")
        XCTAssertFalse(policy.admit(.approvalNeeded, keys: ["rt-2"], requestID: "approval:a1", now: now.addingTimeInterval(1_000)),
                       "a request notifies once, however late it repeats")
        // The registry first, then the stream's request for the same wait.
        XCTAssertTrue(policy.admit(.inputNeeded, keys: ["rt-3"], requestID: nil, now: now))
        XCTAssertFalse(policy.admit(.approvalNeeded, keys: ["rt-3"], requestID: "approval:b1", now: now.addingTimeInterval(3)))
        XCTAssertFalse(policy.admit(.approvalNeeded, keys: ["rt-3"], requestID: "approval:b1", now: now.addingTimeInterval(500)))
    }

    func testMacAttentionReadsWhoStartedWaiting() {
        var policy = MacAttentionPolicy()
        func row(_ id: String, _ status: String) -> LiveSessionStatus {
            LiveSessionStatus(runtimeSessionId: id, storedSessionId: "stored-\(id)", status: status)
        }
        XCTAssertTrue(policy.newlyWaiting([row("a", "working"), row("b", "waiting")], scope: "d|default").isEmpty,
                      "the first snapshot only says where things stand")
        XCTAssertEqual(policy.newlyWaiting([row("a", "waiting"), row("b", "waiting"), row("c", "idle")], scope: "d|default")
            .map(\.runtimeSessionId), ["a"], "only a chat that began to wait")
        XCTAssertTrue(policy.newlyWaiting([row("a", "waiting")], scope: "d|work").isEmpty,
                      "each dashboard's profile starts from its own first snapshot")
        XCTAssertTrue(policy.newlyWaiting([row("a", "idle"), row("c", "idle")], scope: "d|default").isEmpty,
                      "a reply elsewhere is that device's to announce")
        policy.forgetRegistry()
        XCTAssertTrue(policy.newlyWaiting([row("c", "waiting")], scope: "d|default").isEmpty,
                      "after a disconnect the next snapshot starts over")
    }

    func testMacBadgeCountsEachChatOnce() {
        let rows = [("default", "a", true), ("default", "a", true), ("default", "b", false), ("work", "a", true)]
        XCTAssertEqual(MacAttentionPolicy.badgeCount(rows, key: { "\($0.0)\u{1F}\($0.1)" }, needsUser: { $0.2 }), 2)
    }

    func testMacNotificationOpensItsChat() throws {
        let dashboard = UUID()
        let content = UNMutableNotificationContent()
        content.userInfo = [MacAttention.userInfoKey: [
            "session_id": "rt-1", "stored_session_id": "stored-1", "profile": "work",
            "type": "approval.needed", "dashboard_id": dashboard.uuidString,
        ]]
        let request = UNNotificationRequest(identifier: "\(MacAttention.identifierPrefix)waiting-stored-1", content: content, trigger: nil)
        let target = try XCTUnwrap(MacAttention.target(from: request))
        XCTAssertEqual(target.sessionId, "rt-1")
        XCTAssertEqual(target.durableSessionID, "stored-1")
        XCTAssertEqual(target.profile, "work")
        XCTAssertEqual(target.dashboardID, dashboard)
        XCTAssertEqual(target.type, "approval.needed")
        let other = UNNotificationRequest(identifier: "hermes-call-rt-1", content: content, trigger: nil)
        XCTAssertNil(MacAttention.target(from: other), "only a notification Conduit for Mac posted opens this way")
    }
}
#endif
