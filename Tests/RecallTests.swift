import AppKit

@main
struct RecallTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        PetView.recordsActivity = false
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            checks += 1
            guard value() else { fputs("FAILED: \(message)\n", stderr); exit(1) }
        }
        for kind in [AgentKind.claude, .codex] {
            let pane = "recall-test:\(UUID().uuidString)"
            func agent(_ status: String) -> Agent {
                Agent(pane: pane, status: status, title: "", project: "test", kind: kind)
            }
            func pet(_ status: String) -> PetView {
                let result = PetView(agent: agent(status), pokemon: "gengar", sheet: SpriteSheet.named("gengar")!)
                result.update(agent(status))
                return result
            }
            func finishRecall(_ pet: PetView) {
                for _ in 0..<8 { pet.animate() }
            }

            let ready = pet("done")
            check(ready.mood == .done, "An unacknowledged completion must be visible")
            var vanished = 0
            ready.onVanish = { vanished += 1 }
            ready.returnToBall()
            for _ in 0..<12 {
                ready.update(agent("done"))
                ready.animate()
            }
            check(ready.isGone && vanished == 1, "Recalling a ready pet must finish once and stay hidden through polls")
            check(ready.finishedAt == nil, "Repeated done polls must not recreate the consumed completion")
            ready.update(agent("idle"))
            check(ready.isGone, "Acknowledging done must also survive a later idle poll")
            ready.wake()
            ready.land()
            ready.update(agent("idle"))
            check(ready.mood == .idle, "Let Out must honor the consumed completion")

            let repeated = pet("done")
            repeated.returnToBall()
            finishRecall(repeated)
            repeated.wake()
            repeated.land()
            repeated.update(agent("done"))
            check(repeated.mood == .idle && repeated.finishedAt == nil, "Let Out cannot replay an acknowledged done message")
            repeated.update(agent("working"))
            check(repeated.mood == .working, "New work must rearm completion reporting")
            repeated.update(agent("done"))
            check(repeated.mood == .done, "The next completed task must still notify")

            let busy = pet("working")
            busy.returnToBall()
            for _ in 0..<12 {
                busy.update(agent("working"))
                busy.animate()
            }
            check(busy.isGone, "A working pet must stay recalled while the same work continues")
            var summoned = 0
            busy.onSummon = { _ in summoned += 1 }
            busy.update(agent("done"))
            check(busy.mood == .done && busy.arriving && summoned == 1, "Finishing hidden work must summon the pet with its completion")
            busy.land()
            busy.update(agent("done"))
            check(busy.mood == .done && summoned == 1, "Repeated completion polls cannot repeatedly summon the pet")
            busy.returnToBall()
            finishRecall(busy)
            busy.update(agent("done"))
            check(busy.isGone, "The newly received completion can be acknowledged by recalling again")

            let interrupted = pet("working")
            interrupted.returnToBall()
            interrupted.animate()
            interrupted.update(agent("done"))
            check(interrupted.mood == .done && interrupted.transition?.kind == .release,
                  "Completion during the recall animation must bring the pet straight back")

            let idleFinish = pet("working")
            idleFinish.returnToBall()
            finishRecall(idleFinish)
            idleFinish.update(agent("idle"))
            check(idleFinish.mood == .done, "Providers that finish as idle must also notify")

            let attention = pet("working")
            attention.returnToBall()
            finishRecall(attention)
            attention.update(agent("blocked"))
            check(attention.mood == .alert && attention.arriving, "A recalled worker must come out when it needs attention")

            let restart = pet("done")
            restart.returnToBall()
            finishRecall(restart)
            restart.update(agent("working"))
            check(restart.mood == .working && restart.arriving, "New work after a ready recall must summon normally")
        }
        print("Passed \(checks) recall, acknowledgement, completion and attention checks for Claude and Codex.")
    }
}
