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
- Swift 6.0, iOS 17.0 deployment target
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

## Future: macOS Messages Companion
Architecture supports adding `MessagesService` that calls a macOS companion HTTP server (via Cloudflare Tunnel) to serve iMessage/SMS data. Add tools to `ToolDefinitions.swift`, dispatch in `ToolExecutor.swift`.
