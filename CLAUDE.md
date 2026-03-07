# Secretary — iOS Email & Calendar Assistant

## What This Is
Native iOS port of the Python email secretary at `/Users/christopherfretz/git/secretary`. SwiftUI chat interface where Claude manages email (via IMAP) and calendar (via EventKit) through tool use.

## Build & Run
```bash
cd Secretary
# Generate Xcode project (if project.yml changed):
xcodegen generate
# Build:
xcodebuild -project Secretary.xcodeproj -scheme Secretary -destination 'platform=iOS Simulator,name=iPhone 17' build
```
- Swift 6.0, iOS 26.0 deployment target
- XcodeGen project defined in `Secretary/project.yml`
- SPM dependencies: GRDB, SwiftSoup, KeychainAccess, SwiftAnthropic (≥2.2.0)
- Build flag: `-DSQLITE_ENABLE_FTS5` (required for GRDB FTS5 support)

## Architecture

```
Secretary/Secretary/
├── Config/AppConfig.swift          — Constants (IMAP host, batch sizes, agent params)
├── Models/                         — GRDB FetchableRecord/PersistableRecord structs
├── Database/
│   ├── Schema.swift                — 7 tables: folders, messages, messages_fts, staged_changes,
│   │                                 sync_log, rules, conversations
│   ├── DatabaseManager.swift       — GRDB DatabaseQueue (WAL, foreign_keys, busy_timeout)
│   └── *Repository.swift           — Static CRUD methods per table
├── Services/
│   ├── IMAP/
│   │   ├── IMAPConnection.swift    — Actor: NWConnection with TLS to imap.mail.me.com:993
│   │   ├── IMAPClient.swift        — Actor: high-level IMAP commands
│   │   ├── SyncEngine.swift        — 5-phase delta sync (UIDVALIDITY, removal, dedup, fetch, purge)
│   │   └── FlushEngine.swift       — Stage-then-flush: flags → moves → deletes → expunge
│   ├── Claude/
│   │   ├── AgentLoop.swift         — Actor: streaming tool-use loop with AsyncStream<StreamEvent>
│   │   ├── ToolDefinitions.swift   — 26 tools (19 email + 7 calendar) as JSON schemas
│   │   ├── ToolExecutor.swift      — Class: dispatches tool name → service method
│   │   └── SystemPrompt.swift      — Claude system prompt with capabilities
│   ├── Calendar/CalendarService.swift — Actor: EventKit wrapper
│   └── Rules/RulesEngine.swift     — Condition matching, apply rules, stage changes
├── ViewModels/                     — @MainActor ObservableObjects
├── Views/                          — SwiftUI (Chat, Settings, Onboarding)
├── Keychain/KeychainManager.swift  — iCloud email/password + Anthropic API key
└── Extensions/                     — Email parsing, IMAP data helpers
```

### Key Design Decisions
- **No MCP**: Tools defined as Claude API JSON schemas, executed locally. Same functionality, no protocol overhead.
- **Custom IMAP client**: Built on NWConnection (Network.framework) with TLS. Avoids immature Swift IMAP libraries.
- **Stage-then-flush**: All email mutations are queued locally, reviewed, then pushed to IMAP in one batch.
- **ToolExecutor is a class, not actor**: Avoids `[String: Any]` Sendable boundary issues when passing tool arguments.

### Data Flow
1. User sends message → `ChatViewModel` → `AgentLoop.run()`
2. AgentLoop saves to conversation DB, loads history, calls Claude API
3. Claude responds with text and/or tool_use blocks
4. AgentLoop executes tools via `ToolExecutor.execute()`, returns results
5. Loop continues until Claude responds with no tool calls or hits iteration limit
6. `StreamEvent`s flow back to ChatViewModel via AsyncStream

### Cancellation Architecture
- `ChatViewModel.stopStreaming()` cancels `runningTask` AND calls `agentLoop.cancel()`
- `AgentLoop` stores its inner `Task` separately — AsyncStream inner tasks are NOT children of the consuming task
- `AgentLoop.cancel()` sets a `cancelled` flag and cancels the inner task
- `Task.checkCancellation()` is called in `IMAPConnection.readLine()` and in the sync batch loop
- `ToolExecutor.execute()` rethrows `CancellationError` so the agent loop can exit cleanly
- After cancellation, orphaned `tool_use` blocks (no matching `tool_result`) break the Claude API
- `ConversationRepository.repairToolUseHistory()` inserts synthetic `tool_result` blocks for orphaned tool_use

### SyncEngine Phases (6-phase delta sync)
0. Select folder + UIDVALIDITY check (purge local data on change)
1. Track stale UIDs (server-missing, don't delete yet)
2. Discover new UIDs (optionally filtered by SINCE date)
3. Fetch new messages (full headers + bodies, batched, with progress callbacks)
4. Local move dedup — check stale messages against local DB by Message-ID (no remote scan)
5. Purge `\Deleted` flagged messages (skip protected/staged)
6. Update folder state (uidvalidity, lastSyncedUid, uidnext)

### DatabaseManager Recovery
On startup, if the database is corrupted, `DatabaseManager.shared` catches the error, deletes the corrupt DB files, recreates a fresh database, and posts `databaseResetNotification`. `ChatViewModel` listens for this and shows a warning to the user.

## SwiftAnthropic API (v2.2.x)
- Model enum: `.other("model-id")` (not `.custom()`)
- Messages: `MessageParameter.Message(role: .user/.assistant, content: .text(String) | .list([ContentObject]))`
- Content objects: `.text(String)`, `.toolUse(id, name, Input)`, `.toolResult(id, content)`
- Response content: `.text(String, Citations?)`, `.toolUse(ToolUse)` where `ToolUse.input` is `[String: DynamicContent]`
- Tool defs: `.function(name:, description:, inputSchema:, cacheControl:)`
- API: `service.createMessage(parameter)` returns `MessageResponse`

## Swift 6 Concurrency — Lessons Learned

### GRDB in async contexts picks async overloads
All `db.read/db.write` calls in async functions resolve to the `@Sendable` closure overloads. Always use `await`:
```swift
let result = try await db.read { db in ... }
```

### Never capture `var` in db.read/db.write closures
Snapshot to `let` before the closure, return values out:
```swift
let snapshot = mutableVar
let result = try await db.write { db in /* use snapshot */ }
mutableVar = result
```

### `[String: Any]` is not Sendable
- Can't pass across actor boundaries or return from `@Sendable` closures
- **Fix**: Format to `String` inside closures, or serialize to JSON before crossing boundaries
- **Fix**: Use `class @unchecked Sendable` instead of `actor` when methods accept `[String: Any]`

### Non-Sendable static properties
Third-party types (like `MessageParameter.Tool`) that aren't marked Sendable cause errors on `static let`. Fix:
```swift
nonisolated(unsafe) static let tools: [MessageParameter.Tool] = [...]
```

### Complex dictionary literals can timeout the type-checker
Break `StatementArguments([large dict literal])` into a separate `let args: [String: (any DatabaseValueConvertible)?] = [...]` then `StatementArguments(args)`.

### `@preconcurrency import` for third-party Sendable gaps
```swift
@preconcurrency import SwiftAnthropic
```

### @MainActor closures escape to background queues
The `App` protocol is `@MainActor`. Closures defined in `App.init()` inherit `@MainActor` isolation. If those closures are called on background queues (e.g., BGTask handlers), Swift 6 runtime traps with `EXC_BREAKPOINT` in `dispatch_assert_queue_fail`. **Fix**: move registration to a `nonisolated static func`:
```swift
init() { Self.registerBackgroundTask() }
nonisolated static func registerBackgroundTask() {
    BGTaskScheduler.shared.register(...) { task in /* not @MainActor */ }
}
```

### PRAGMA journal_mode=WAL must be outside a transaction
`PRAGMA journal_mode=WAL` fails inside a transaction. GRDB's `db.write { }` wraps in a transaction. Use `writeWithoutTransaction` instead:
```swift
try dbQueue.writeWithoutTransaction { db in
    try db.execute(sql: "PRAGMA journal_mode=WAL")
}
```

## Background Execution — BGContinuedProcessingTask (iOS 26+)

### Architecture
- `SecretaryApp.registerBackgroundTask()` — registers handler (must be `nonisolated static`)
- `BackgroundTaskCoordinator` — thread-safe singleton (`@unchecked Sendable` + NSLock), NOT `@MainActor`
- `ChatViewModel.beginBackgroundProcessing()` — submits BGContinuedProcessingTaskRequest, falls back to `beginBackgroundTask` on Simulator
- `ChatViewModel.endBackgroundProcessing()` — calls `markFinished()` to unblock the handler

### Critical rules
1. **Handler MUST block** — returning immediately from the BGTask handler causes SIGTRAP. Use `while !isFinished && !wasExpired { sleep(1) }`
2. **Handler must NOT be @MainActor** — see concurrency section above
3. **Not supported on Simulator** — submit() throws `BGTaskSchedulerErrorCodeUnavailable` (code 1). Always fall back to `beginBackgroundTask`
4. **No UIBackgroundModes needed** — `BGContinuedProcessingTask` does NOT require `UIBackgroundModes: processing` in Info.plist
5. **Identifier pattern** — use `$(PRODUCT_BUNDLE_IDENTIFIER).background` in Info.plist, `"\(Bundle.main.bundleIdentifier!).background"` in code
6. **Set `request.strategy = .queue`** explicitly

## Runtime Pitfalls — Lessons from Debugging

### Swift `Data` slicing is index-unsafe
After `buffer.removeFirst(n)`, the resulting `Data` is a *slice* with a non-zero `startIndex`. Subscripting from index 0 crashes. **Always normalize slices** with `Data(buffer[range...])` or use Foundation's built-in `Data.range(of:)` which handles indices correctly. Never write custom `Data.range(of:)` extensions — they shadow Foundation's correct implementation.

### Avoid O(n²) string replacement patterns
`while text.contains(x) { text = text.replacingOccurrences(...) }` is O(n²) on large strings. Use single-pass character scanning instead. This caused 100% CPU hangs on large HTML emails in `MessageParser.htmlToText()`.

### Batch DB operations in sync paths
Individual `db.read` calls per message (e.g., `findByMessageId` in a loop) create thousands of async DB roundtrips and appear to hang. Use batch `IN (...)` queries in a single transaction instead. See `MessageRepository.findByMessageIds()`.

### IMAP move dedup should be local-only
The original design fetched Message-ID headers via IMAP to detect moves. This is an unnecessary extra IMAP pass. Instead: fetch all new messages directly, then check stale (server-missing) messages against the *local* DB by Message-ID to detect moves.

### AsyncStream inner tasks need explicit cancellation
Tasks launched inside an `AsyncStream` builder are NOT children of the task consuming the stream. Store the inner `Task` and cancel it explicitly in the actor's `cancel()` method.

### Claude API requires tool_result for every tool_use
After cancelling mid-tool-execution, orphaned `tool_use` blocks in the conversation DB cause API errors on the next request. `ConversationRepository.repairToolUseHistory()` scans all messages and inserts synthetic `tool_result` blocks for any unmatched `tool_use`.

## Diagnostics

### Simulator
```bash
xcrun simctl io booted screenshot /tmp/sim.png
sample <pid> 3
ls ~/Library/Logs/DiagnosticReports/Secretary-*.ips
xcrun simctl get_app_container booted com.secretary.ios data
sqlite3 <container>/Library/Application\ Support/Secretary/secretary.db
log show --predicate 'subsystem == "Secretary"' --last 5m
```

### Device (UDID: 00008150-0002456A0C47801C)
```bash
# Install and launch with console output
xcrun devicectl device install app --device 00008150-0002456A0C47801C <path-to>.app
xcrun devicectl device process launch --device 00008150-0002456A0C47801C --console com.secretary.ios
# Use NSLog (not os.Logger) — NSLog shows up in --console output reliably
```

## Future: macOS Messages Companion
Architecture supports adding `MessagesService` that calls a macOS companion HTTP server (via Cloudflare Tunnel) to serve iMessage/SMS data. Add tools to `ToolDefinitions.swift`, dispatch in `ToolExecutor.swift`.
