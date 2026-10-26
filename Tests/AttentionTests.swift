import AppKit
import SQLite3

@main
struct AttentionTests {
    @MainActor static func main() throws {
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            guard value() else { fatalError(message) }
        }
        func event(_ type: String, _ payload: [String: Any]) -> Data {
            var data = try! JSONSerialization.data(withJSONObject: ["type": type, "payload": payload], options: [.sortedKeys])
            data.append(10)
            return data
        }
        func boundary(_ name: String) -> Data { event("event_msg", ["type": name]) }
        func call(_ id: String, _ name: String, _ type: String = "function_call") -> Data {
            event("response_item", ["type": type, "call_id": id, "name": name])
        }
        func output(_ id: String, _ result: String, _ type: String = "function_call_output") -> Data {
            event("response_item", ["type": type, "call_id": id, "output": result])
        }
        let user = event("response_item", ["type": "message", "role": "user", "content": []])
        var state = CodexActivity.State()
        state.consume(boundary("task_started"))
        state.consume(call("sync", "functions.request_user_input"))
        check(state.status == "blocked", "A normal function-call question must need attention")
        state.consume(output("other", "{}"))
        check(state.status == "blocked", "Unrelated tool output must not clear a question")
        state.consume(output("sync", "{\"answers\":{}}"))
        check(state.status == "working", "The matching answer must clear a synchronous question")
        state.consume(call("legacy", "request_user_input", "custom_tool_call"))
        check(state.status == "blocked", "Older custom calls must still be supported")
        state.consume(output("legacy", "answer", "custom_tool_call_output"))
        check(state.status == "working", "Older matching outputs must clear attention")
        state.consume(call("async", "request_user_input_async"))
        state.consume(output("async", "{\"accepted\":true}"))
        check(state.status == "blocked", "Accepted is not an answer to an async question")
        state.consume(call("work", "exec", "custom_tool_call"))
        state.consume(output("work", "background work finished", "custom_tool_call_output"))
        state.consume(boundary("task_complete"))
        check(state.status == "blocked", "Async attention must survive other work and turn completion")
        state.consume(user)
        check(state.status == "done", "A user reply must clear the asynchronous question")
        state.consume(boundary("task_started"))
        state.consume(call("one", "request_user_input"))
        state.consume(call("two", "request_user_input"))
        state.consume(output("one", "answer"))
        check(state.status == "blocked", "Other outstanding questions must stay active")
        state.consume(output("two", "answer"))
        check(state.status == "working", "All answered questions must clear attention")
        state.consume(call("cancel", "request_user_input_async"))
        state.consume(output("cancel", "{\"accepted\":false}"))
        check(state.status == "working", "A rejected async request must not leave stale attention")
        state.consume(call("abort", "request_user_input_async"))
        state.consume(boundary("turn_aborted"))
        check(state.status == "idle", "Aborting the turn must clear its questions")
        state.consume(boundary("task_started"))
        state.consume(call("finish", "request_user_input"))
        state.consume(boundary("task_complete"))
        check(state.status == "done", "A completed blocking turn must not leave stale attention")
        state.consume(Data("not json".utf8))
        check(state.status == "done", "Invalid log lines must be ignored")
        state.consume(event("event_msg", ["type": "token_count", "info": [
            "last_token_usage": ["total_tokens": 250], "model_context_window": 1000
        ]]))
        check(state.context == 0.25, "Attention changes must preserve context reporting")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("attention-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("rollout.jsonl")
        var log = boundary("task_started")
        log.append(call("persist", "request_user_input_async"))
        log.append(output("persist", "{\"accepted\":true}"))
        log.append(output("large", String(repeating: "x", count: 700_000)))
        try log.write(to: file)
        let store = CodexSessions.Store(home: directory.path)
        var db: OpaquePointer?
        check(sqlite3_open(store.database, &db) == SQLITE_OK, "Fixture database must open")
        defer { sqlite3_close(db) }
        check(sqlite3_exec(db, "CREATE TABLE threads (id TEXT, rollout_path TEXT, archived INTEGER);", nil, nil, nil) == SQLITE_OK,
              "Fixture table must be created")
        var insert: OpaquePointer?
        check(sqlite3_prepare_v2(db, "INSERT INTO threads VALUES ('fixture', ?, 0);", -1, &insert, nil) == SQLITE_OK,
              "Fixture insert must prepare")
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(insert, 1, file.path, -1, transient)
        check(sqlite3_step(insert) == SQLITE_DONE, "Fixture insert must succeed")
        sqlite3_finalize(insert)
        check(CodexSessions.waitingForInput(["fixture", "missing"], in: [store]) == ["fixture"],
              "Conductor thread IDs must resolve to their pending questions without a CLI writer lock")
        check(CodexActivity.read(file.path)?.status == "blocked", "Questions older than a short log tail must be found")
        check(CodexActivity.read(file.path)?.status == "blocked", "An unchanged cached log must keep attention")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        let halfway = user.count / 2
        try handle.write(contentsOf: user.prefix(halfway))
        check(CodexActivity.read(file.path)?.status == "blocked", "A partial JSON line must wait for the remaining bytes")
        try handle.write(contentsOf: user.suffix(user.count - halfway))
        try handle.close()
        check(CodexActivity.read(file.path)?.status == "working", "An appended reply must clear attention")
        check(CodexSessions.waitingForInput(["fixture"], in: [store]).isEmpty,
              "The Conductor lookup must stop reporting attention after a reply")
        let reopened = directory.appendingPathComponent("reopened.jsonl")
        try Data(contentsOf: file).write(to: reopened)
        check(CodexActivity.read(reopened.path)?.status == "working", "A fresh read must recover the same answered state")
        try boundary("turn_aborted").write(to: file)
        check(CodexActivity.read(file.path)?.status == "idle", "Truncated or replaced logs must reset cached questions")
        try FileManager.default.removeItem(at: file)
        check(CodexActivity.read(file.path) == nil, "Missing logs must not retain cached attention")

        #if POKEMON
        PetView.recordsActivity = false
        let agent = Agent(pane: "attention-test:\(UUID().uuidString)", status: "blocked", title: "", project: "test")
        let pet = PetView(agent: agent, pokemon: "gengar", sheet: SpriteSheet.named("gengar")!)
        pet.update(agent)
        check(pet.mood == .alert, "Blocked state must select the existing red attention animation")
        let working = Agent(pane: agent.pane, status: "working", title: "", project: "test")
        pet.update(working)
        check(pet.mood == .working, "Resuming work must stop the red attention animation")
        #endif
        if CommandLine.arguments.contains("--live") {
            let start = Date()
            let agents = Conductor.agents(records: []) ?? []
            print("Live Conductor integration: \(agents.count) chats, \(agents.filter { $0.status == "blocked" }.count) need attention; initial scan \(String(format: "%.2f", Date().timeIntervalSince(start)))s.")
            let cached = Date()
            _ = Conductor.agents(records: [])
            print("Cached poll: \(String(format: "%.3f", Date().timeIntervalSince(cached)))s.")
        }
        print("Passed sync/async questions, matching answers, lifecycle, context, and incremental log checks.")
    }
}
