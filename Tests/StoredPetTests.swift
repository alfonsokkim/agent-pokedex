import AppKit

@main
struct StoredPetTests {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        PetView.recordsActivity = false
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
        }
        let start = Date().timeIntervalSince1970
        let deadline = start + StoredPetHistory.lifetime
        var history = StoredPetHistory()
        history.observe(pane: "old", stored: true, since: start)
        history.observe(pane: "old", stored: true, since: start + 500)
        check(history.storedSince["old"] == start, "Polling must not extend retention")
        check(history.expire(now: deadline - 0.001).isEmpty, "Keep stored pets for the full two weeks")
        check(history.expire(now: deadline) == ["old"], "Expire at the two-week boundary")
        check(!history.admits(pane: "old", status: "done", activityAt: start), "Stale completion cannot recreate an expired pet")
        history = try JSONDecoder().decode(StoredPetHistory.self, from: JSONEncoder().encode(history))
        check(!history.admits(pane: "old", status: "idle", activityAt: start), "Expiry survives restart")
        check(history.admits(pane: "old", status: "done", activityAt: deadline + 1), "Fast new replies restore expired pets")
        history.observe(pane: "active", stored: true, since: start)
        history.observe(pane: "active", stored: false, since: start + 1)
        check(history.expire(now: deadline).isEmpty, "Letting a pet out cancels its old storage period")
        history.observe(pane: "herdr", stored: true, since: start)
        _ = history.expire(now: deadline, revisions: ["herdr": "42"])
        check(!history.admits(pane: "herdr", status: "done", activityAt: nil, revision: "42"), "A stale herdr state cannot recreate its pet")
        check(history.admits(pane: "herdr", status: "done", activityAt: nil, revision: "44"), "Fast herdr work can return via its state sequence")

        let suite = "stored-pet-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let pane = "codex:retention-\(UUID().uuidString)"
        let idle = Agent(pane: pane, status: "idle", title: "test", project: "test", activityAt: start - 10)
        var controller = AppDelegate(defaults: defaults, createsPanels: false)
        controller.assignments[pane] = "gengar"
        controller.positions["gengar"] = "{0, 0}"
        defaults.set([pane: ["pokemon": "gengar", "shiny": true]], forKey: ShinyEncounters.key)
        defaults.set([pane: start], forKey: LastActive.key)
        defaults.set([String(pane.dropFirst(CodexSessions.prefix.count)): start], forKey: "codexSeen")
        controller.sync([idle], now: Date(timeIntervalSince1970: start))
        let original = controller.pets[pane]!
        original.returnToBall()
        for _ in 0..<8 { original.animate() }
        controller.sync([idle], now: Date(timeIntervalSince1970: start))
        check(controller.storedHistory.storedSince[pane] == start, "Manual recall starts a real retention clock")
        controller.sync([idle], now: Date(timeIntervalSince1970: deadline - 0.001))
        check(controller.pets[pane]?.isGone == true, "A recently stored pet remains available in Let Out")
        controller.sync([idle], now: Date(timeIntervalSince1970: deadline))
        check(controller.pets[pane] == nil && !controller.order.contains(pane), "Expired pets leave the list and controller")
        check(controller.assignments[pane] == nil && controller.positions["gengar"] == nil, "Expiry clears species and unshared position")
        check(defaults.dictionary(forKey: ShinyEncounters.key)?[pane] == nil, "Expiry clears the shiny appearance")
        check(defaults.dictionary(forKey: LastActive.key)?[pane] == nil, "Expiry clears old activity tracking")
        check(defaults.dictionary(forKey: "codexSeen")?.isEmpty == true, "Expiry clears acknowledgement metadata")
        controller.sync([idle], now: Date(timeIntervalSince1970: deadline + 1))
        check(controller.pets.isEmpty && controller.assignments.isEmpty, "Repeated discovery cannot immediately recreate an expired pet")
        controller = AppDelegate(defaults: defaults, createsPanels: false)
        controller.sync([idle], now: Date(timeIntervalSince1970: deadline + 2))
        check(controller.pets.isEmpty, "Restart cannot resurrect a stale stored pet")
        let fresh = Agent(pane: pane, status: "done", title: idle.title, project: idle.project, activityAt: deadline + 3)
        controller.sync([fresh], now: Date(timeIntervalSince1970: deadline + 4))
        check(controller.pets[pane] != nil && controller.assignments[pane] != nil, "New conversation activity assigns a fresh random pet")
        check(controller.pets[pane] !== original, "Returning after expiry creates a new encounter")

        let disconnected = "missing-agent"
        controller.assignments[disconnected] = "pikachu"
        controller.storedHistory.storedSince[disconnected] = start
        controller.sync([fresh], now: Date(timeIntervalSince1970: deadline + 5))
        check(controller.assignments[disconnected] == nil, "Disconnected agents' old assignments are also cleaned up")
        let busy = Agent(pane: "busy-retention-test", status: "working", title: "", project: "test")
        controller.sync([fresh, busy], now: Date(timeIntervalSince1970: deadline + 6))
        controller.pets[busy.pane]!.returnToBall()
        controller.storedHistory.storedSince[busy.pane] = start
        controller.sync([fresh, busy], now: Date(timeIntervalSince1970: deadline + 10))
        check(controller.pets[busy.pane] != nil && controller.assignments[busy.pane] != nil,
              "A hidden agent that is still working cannot expire")
        check(controller.storedHistory.storedSince[busy.pane] == nil, "Busy agents do not accumulate a stale storage clock")

        let restartSuite = "stored-restart-tests-\(UUID().uuidString)"
        let restartDefaults = UserDefaults(suiteName: restartSuite)!
        defer { restartDefaults.removePersistentDomain(forName: restartSuite) }
        let ready = Agent(pane: "restart-stored-ready", status: "done", title: "", project: "test", activityAt: start - 1)
        var restarted = AppDelegate(defaults: restartDefaults, createsPanels: false)
        restarted.assignments[ready.pane] = "gengar"
        restarted.sync([ready], now: Date(timeIntervalSince1970: start))
        let oldReady = restarted.pets[ready.pane]!
        oldReady.returnToBall()
        for _ in 0..<8 { oldReady.animate() }
        restarted.sync([ready], now: Date(timeIntervalSince1970: start))
        restarted = AppDelegate(defaults: restartDefaults, createsPanels: false)
        restarted.sync([ready], now: Date(timeIntervalSince1970: start + 60))
        check(restarted.pets[ready.pane]?.isGone == true, "Restart preserves a stored ready pet without replaying done")
        var afterExpiry = ready
        afterExpiry.activityAt = deadline + 5
        restarted = AppDelegate(defaults: restartDefaults, createsPanels: false)
        restarted.sync([afterExpiry], now: Date(timeIntervalSince1970: deadline + 10))
        check(restarted.pets[ready.pane] != nil && restarted.pets[ready.pane] !== oldReady,
              "Expiry while closed is applied before new activity creates its fresh encounter")

        restarted.pets[ready.pane]!.returnToBall()
        for _ in 0..<8 { restarted.pets[ready.pane]!.animate() }
        restarted.sync([afterExpiry], now: Date(timeIntervalSince1970: deadline + 11))
        afterExpiry.activityAt = deadline + 12
        restarted.sync([afterExpiry], now: Date(timeIntervalSince1970: deadline + 13))
        check(restarted.pets[ready.pane]?.mood == .done, "Fast new completion rearms a recalled pet's acknowledged caption")
        restarted.pets[ready.pane]!.returnToBall()
        afterExpiry.activityAt = deadline + 14
        restarted.sync([afterExpiry], now: Date(timeIntervalSince1970: deadline + 15))
        check(restarted.pets[ready.pane]?.mood == .done, "New activity during recall cannot be swallowed by its animation")

        var log = CodexActivity.State()
        let event: [String: Any] = ["timestamp": "2026-11-02T10:20:30.125Z", "type": "event_msg",
                                  "payload": ["type": "user_message"]]
        log.consume(try JSONSerialization.data(withJSONObject: event))
        check(log.activityAt != nil, "Codex user messages supply real activity timestamps")
        let savedActivity = log.activityAt
        let tokenEvent: [String: Any] = ["timestamp": "2026-11-02T11:20:30Z", "type": "event_msg",
                                       "payload": ["type": "token_count"]]
        log.consume(try JSONSerialization.data(withJSONObject: tokenEvent))
        check(log.activityAt == savedActivity, "Metadata updates cannot resurrect forgotten pets")
        print("Passed \(checks) two-week retention, cleanup, restart and reactivation checks.")
    }
}
