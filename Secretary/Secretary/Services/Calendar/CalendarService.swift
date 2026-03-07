import EventKit
import Foundation

/// EventKit wrapper for calendar operations.
actor CalendarService {
    private let eventStore = EKEventStore()
    private var hasAccess = false

    private func ensureAccess() async throws {
        guard !hasAccess else { return }
        let granted = try await eventStore.requestFullAccessToEvents()
        guard granted else {
            throw SecretaryError.validation("Calendar access denied. Please enable in Settings.")
        }
        hasAccess = true
    }

    private func parseDate(_ str: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: str) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: str) { return d }
        // Try date-only
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        if let d = df.date(from: str) { return d }
        // Try with time
        df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return df.date(from: str)
    }

    private func formatEvent(_ event: EKEvent) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        let start = df.string(from: event.startDate)
        let end = df.string(from: event.endDate)
        var lines = [
            "ID: \(event.eventIdentifier ?? "")",
            "Title: \(event.title ?? "")",
            "Start: \(start)",
            "End: \(end)",
            "Calendar: \(event.calendar?.title ?? "")",
        ]
        if event.isAllDay { lines.append("All Day: yes") }
        if let loc = event.location, !loc.isEmpty { lines.append("Location: \(loc)") }
        if let notes = event.notes, !notes.isEmpty { lines.append("Notes: \(notes)") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Tool implementations

    func listCalendars() async throws -> String {
        try await ensureAccess()
        let calendars = eventStore.calendars(for: .event)
        var lines = ["Calendars (\(calendars.count)):"]
        for cal in calendars {
            lines.append("  \(cal.title) (\(cal.source.title))")
        }
        return lines.joined(separator: "\n")
    }

    func getEvents(startDate: String, endDate: String, calendarName: String? = nil) async throws -> String {
        try await ensureAccess()
        guard let start = parseDate(startDate), let end = parseDate(endDate) else {
            return "Invalid date format. Use ISO format (e.g. '2026-03-07')."
        }
        var calendars: [EKCalendar]? = nil
        if let calendarName {
            calendars = eventStore.calendars(for: .event).filter { $0.title == calendarName }
            if calendars?.isEmpty == true { return "Calendar '\(calendarName)' not found." }
        }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = eventStore.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        if events.isEmpty { return "No events found in that date range." }
        let lines = events.map { e in
            let df = DateFormatter()
            df.dateFormat = "HH:mm"
            let time = e.isAllDay ? "all day" : df.string(from: e.startDate)
            return "  [\(e.eventIdentifier ?? "")] \(time) - \(e.title ?? "")"
        }
        return "\(events.count) event(s):\n" + lines.joined(separator: "\n")
    }

    func getEvent(eventId: String) async throws -> String {
        try await ensureAccess()
        guard let event = eventStore.event(withIdentifier: eventId) else {
            return "Event not found."
        }
        return formatEvent(event)
    }

    func createEvent(title: String, startDate: String, endDate: String,
                     calendarName: String? = nil, location: String? = nil,
                     notes: String? = nil, allDay: Bool = false) async throws -> String {
        try await ensureAccess()
        guard let start = parseDate(startDate), let end = parseDate(endDate) else {
            return "Invalid date format."
        }
        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        event.location = location
        event.notes = notes

        if let calendarName {
            if let cal = eventStore.calendars(for: .event).first(where: { $0.title == calendarName }) {
                event.calendar = cal
            }
        }
        if event.calendar == nil {
            event.calendar = eventStore.defaultCalendarForNewEvents
        }

        try eventStore.save(event, span: .thisEvent)
        return "Created event: \(title)\nID: \(event.eventIdentifier ?? "")"
    }

    func updateEvent(eventId: String, title: String? = nil, startDate: String? = nil,
                     endDate: String? = nil, location: String? = nil, notes: String? = nil) async throws -> String {
        try await ensureAccess()
        guard let event = eventStore.event(withIdentifier: eventId) else {
            return "Event not found."
        }
        if let title { event.title = title }
        if let startDate, let d = parseDate(startDate) { event.startDate = d }
        if let endDate, let d = parseDate(endDate) { event.endDate = d }
        if let location { event.location = location }
        if let notes { event.notes = notes }

        try eventStore.save(event, span: .thisEvent)
        return "Updated event: \(event.title ?? "")"
    }

    func deleteEvent(eventId: String) async throws -> String {
        try await ensureAccess()
        guard let event = eventStore.event(withIdentifier: eventId) else {
            return "Event not found."
        }
        let title = event.title ?? ""
        try eventStore.remove(event, span: .thisEvent)
        return "Deleted event: \(title)"
    }

    func searchEvents(query: String, startDate: String? = nil, endDate: String? = nil) async throws -> String {
        try await ensureAccess()
        let start = startDate.flatMap(parseDate) ?? Date().addingTimeInterval(-30 * 86400)
        let end = endDate.flatMap(parseDate) ?? Date().addingTimeInterval(365 * 86400)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { e in
                let q = query.lowercased()
                return (e.title?.lowercased().contains(q) ?? false) ||
                       (e.notes?.lowercased().contains(q) ?? false) ||
                       (e.location?.lowercased().contains(q) ?? false)
            }
            .sorted { $0.startDate < $1.startDate }

        if events.isEmpty { return "No events matching '\(query)'." }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let lines = events.map { e in
            "  [\(e.eventIdentifier ?? "")] \(df.string(from: e.startDate)) - \(e.title ?? "")"
        }
        return "\(events.count) event(s) matching '\(query)':\n" + lines.joined(separator: "\n")
    }
}
