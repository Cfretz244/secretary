import Foundation
import SwiftAnthropic

/// All tool definitions in Claude API format. Port of tools.py TOOL_DEFINITIONS.
enum ToolDefinitions {
    nonisolated(unsafe) static let all: [MessageParameter.Tool] = emailTools + calendarTools

    // MARK: - Email Tools (19)

    nonisolated(unsafe) static let emailTools: [MessageParameter.Tool] = [
        .function(
            name: "sync_folder",
            description: "Delta sync one IMAP folder to local cache.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "folder": .init(type: .string, description: "Folder name to sync"),
                    "since": .init(type: .string, description: "Optional ISO date (e.g. '2026-02-25'). Only sync messages on or after this date."),
                ],
                required: ["folder"]
            )
        ),
        .function(
            name: "sync_all",
            description: "Delta sync all IMAP folders to local cache.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "since": .init(type: .string, description: "Optional ISO date. Only sync messages on or after this date."),
                ],
                required: nil
            )
        ),
        .function(
            name: "search_messages",
            description: "Search local message cache using full-text search and/or filters.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "query": .init(type: .string, description: "Full-text search query"),
                    "folder": .init(type: .string, description: "Filter by folder name"),
                    "sender": .init(type: .string, description: "Filter by sender email (partial match)"),
                    "date_from": .init(type: .string, description: "Filter messages on or after this date (ISO format)"),
                    "date_to": .init(type: .string, description: "Filter messages on or before this date (ISO format)"),
                    "flags": .init(type: .string, description: "Filter by flag"),
                    "unread_only": .init(type: .boolean, description: "Show only unread messages"),
                    "page": .init(type: .integer, description: "Page number (1-based)"),
                    "page_size": .init(type: .integer, description: "Results per page"),
                ],
                required: nil
            )
        ),
        .function(
            name: "get_message",
            description: "Get full message details by local database ID.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "message_id": .init(type: .integer, description: "Local database ID of the message"),
                    "max_body_chars": .init(type: .integer, description: "Max body characters to return. Set to 0 for full body."),
                ],
                required: ["message_id"]
            )
        ),
        .function(
            name: "get_messages",
            description: "Get a paginated list of messages.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "folder": .init(type: .string, description: "Filter by folder"),
                    "page": .init(type: .integer, description: "Page number (1-based)"),
                    "page_size": .init(type: .integer, description: "Results per page"),
                    "sort_by": .init(type: .string, description: "Sort field"),
                    "sort_order": .init(type: .string, description: "ASC or DESC"),
                ],
                required: nil
            )
        ),
        .function(
            name: "stage_move",
            description: "Stage a message move to a target folder.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "message_id": .init(type: .integer, description: "Local database ID of the message"),
                    "target_folder": .init(type: .string, description: "Destination folder name"),
                ],
                required: ["message_id", "target_folder"]
            )
        ),
        .function(
            name: "stage_flag",
            description: "Stage a flag change on a message.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "message_id": .init(type: .integer, description: "Local database ID of the message"),
                    "flag_name": .init(type: .string, description: "Flag name (seen, flagged, answered, draft) or raw IMAP flag"),
                    "remove": .init(type: .boolean, description: "If true, stage flag removal instead of addition"),
                ],
                required: ["message_id", "flag_name"]
            )
        ),
        .function(
            name: "stage_delete",
            description: "Stage a message for deletion.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "message_id": .init(type: .integer, description: "Local database ID of the message"),
                ],
                required: ["message_id"]
            )
        ),
        .function(
            name: "unstage",
            description: "Remove a staged change by its ID.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "change_id": .init(type: .integer, description: "ID of the staged change to remove"),
                ],
                required: ["change_id"]
            )
        ),
        .function(
            name: "clear_staged",
            description: "Drop all staged changes. Optionally limit to a single folder.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "folder": .init(type: .string, description: "Only clear staged changes for this folder"),
                ],
                required: nil
            )
        ),
        .function(
            name: "show_staged_changes",
            description: "Show all pending staged changes.",
            inputSchema: JSONSchema(type: .object, properties: nil, required: nil)
        ),
        .function(
            name: "flush_changes",
            description: "Push all staged changes to IMAP. IMPORTANT: Only call after show_staged_changes and verification.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "dry_run": .init(type: .boolean, description: "If true, show what would happen without making changes"),
                ],
                required: nil
            )
        ),
        .function(
            name: "sender_histogram",
            description: "Get a histogram of senders: message count, date range, and example subject.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "folder": .init(type: .string, description: "Filter by folder"),
                    "min_count": .init(type: .integer, description: "Only include senders with at least this many messages"),
                    "page": .init(type: .integer, description: "Page number (1-based)"),
                    "page_size": .init(type: .integer, description: "Results per page"),
                    "include_deleted": .init(type: .boolean, description: "Include messages with \\Deleted flag"),
                ],
                required: nil
            )
        ),
        .function(
            name: "get_summary",
            description: "Get email statistics: unread count, by-folder breakdown, top senders, recent activity.",
            inputSchema: JSONSchema(type: .object, properties: nil, required: nil)
        ),
        .function(
            name: "list_folders",
            description: "List all IMAP folders with sync status and pending change counts.",
            inputSchema: JSONSchema(type: .object, properties: nil, required: nil)
        ),
        .function(
            name: "create_rule",
            description: "Save a persistent mail rule.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "name": .init(type: .string, description: "Unique name for the rule"),
                    "conditions": .init(type: .array, description: "List of {field, op, value} condition dicts"),
                    "action": .init(type: .string, description: "What to do: move, flag, unflag, or delete"),
                    "action_target": .init(type: .string, description: "Target folder or flag name"),
                    "priority": .init(type: .integer, description: "Lower number = runs first"),
                ],
                required: ["name", "conditions", "action"]
            )
        ),
        .function(
            name: "list_rules",
            description: "Show all rules with conditions and actions.",
            inputSchema: JSONSchema(type: .object, properties: nil, required: nil)
        ),
        .function(
            name: "apply_rules",
            description: "Run saved rules and stage changes.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "folder": .init(type: .string, description: "Limit to messages in this folder"),
                    "rule_id": .init(type: .integer, description: "Run only this rule"),
                ],
                required: nil
            )
        ),
        .function(
            name: "apply_ad_hoc",
            description: "One-shot: define conditions inline, stage matches, don't save the rule.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "conditions": .init(type: .array, description: "List of {field, op, value} condition dicts"),
                    "action": .init(type: .string, description: "What to do: move, flag, unflag, or delete"),
                    "action_target": .init(type: .string, description: "Target folder or flag name"),
                    "folder": .init(type: .string, description: "Limit to messages in this folder"),
                    "limit": .init(type: .integer, description: "Max changes to stage"),
                ],
                required: ["conditions", "action"]
            )
        ),
    ]

    // MARK: - Calendar Tools (7)

    nonisolated(unsafe) static let calendarTools: [MessageParameter.Tool] = [
        .function(
            name: "list_calendars",
            description: "List all available calendars.",
            inputSchema: JSONSchema(type: .object, properties: nil, required: nil)
        ),
        .function(
            name: "get_events",
            description: "Get calendar events in a date range.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "start_date": .init(type: .string, description: "Start date (ISO format, e.g. '2026-03-07')"),
                    "end_date": .init(type: .string, description: "End date (ISO format)"),
                    "calendar_name": .init(type: .string, description: "Filter by calendar name"),
                ],
                required: ["start_date", "end_date"]
            )
        ),
        .function(
            name: "get_event",
            description: "Get event details by identifier.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "event_id": .init(type: .string, description: "Event identifier"),
                ],
                required: ["event_id"]
            )
        ),
        .function(
            name: "create_event",
            description: "Create a new calendar event.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "title": .init(type: .string, description: "Event title"),
                    "start_date": .init(type: .string, description: "Start date/time (ISO format)"),
                    "end_date": .init(type: .string, description: "End date/time (ISO format)"),
                    "calendar_name": .init(type: .string, description: "Calendar to add to (uses default if omitted)"),
                    "location": .init(type: .string, description: "Event location"),
                    "notes": .init(type: .string, description: "Event notes"),
                    "all_day": .init(type: .boolean, description: "Whether this is an all-day event"),
                ],
                required: ["title", "start_date", "end_date"]
            )
        ),
        .function(
            name: "update_event",
            description: "Update an existing calendar event.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "event_id": .init(type: .string, description: "Event identifier"),
                    "title": .init(type: .string, description: "New title"),
                    "start_date": .init(type: .string, description: "New start date/time"),
                    "end_date": .init(type: .string, description: "New end date/time"),
                    "location": .init(type: .string, description: "New location"),
                    "notes": .init(type: .string, description: "New notes"),
                ],
                required: ["event_id"]
            )
        ),
        .function(
            name: "delete_event",
            description: "Delete a calendar event.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "event_id": .init(type: .string, description: "Event identifier"),
                ],
                required: ["event_id"]
            )
        ),
        .function(
            name: "search_events",
            description: "Search calendar events by text.",
            inputSchema: JSONSchema(
                type: .object,
                properties: [
                    "query": .init(type: .string, description: "Search text"),
                    "start_date": .init(type: .string, description: "Search from this date"),
                    "end_date": .init(type: .string, description: "Search until this date"),
                ],
                required: ["query"]
            )
        ),
    ]
}
