import Foundation
import WebKit

// Adds and removes "blocked time" in Fresha using the login the person made inside this app.
final class FreshaClient {
    private let session: URLSession
    private let clientVersion = "2.8.13626"

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.timeoutIntervalForRequest = 15
        session = URLSession(configuration: cfg)
    }

    @MainActor
    private func cookieHeader() async -> String {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.filter { $0.domain.contains("fresha") }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private struct LoginNeeded: Error {}
    private struct Failed: Error { let text: String }

    private func graphql(_ op: String, query: String, variables: [String: Any]) async throws -> [String: Any] {
        // Blocked time lives on Fresha's staff-working-hours service, not the calendar gateway.
        var comps = URLComponents(string: "https://staff-working-hours-api.fresha.com/graphql")!
        comps.queryItems = [URLQueryItem(name: "_client_platform", value: "web"), URLQueryItem(name: "_client_version", value: clientVersion)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        let cookie = await cookieHeader()
        if cookie.isEmpty { throw LoginNeeded() }
        req.setValue(cookie, forHTTPHeaderField: "Cookie")
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://partners.fresha.com", forHTTPHeaderField: "Origin")
        req.setValue("https://partners.fresha.com/", forHTTPHeaderField: "Referer")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["operationName": op, "query": query, "variables": variables])
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw LoginNeeded() }
        guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failed(text: "Fresha HTTP \(status)") }
        if let errs = json["errors"] as? [[String: Any]], !errs.isEmpty {
            let msg = (errs.first?["message"] as? String) ?? "error"
            if msg.lowercased().contains("auth") || msg.lowercased().contains("unauthenticated") { throw LoginNeeded() }
            throw Failed(text: String(msg.prefix(120)))
        }
        return json
    }


    private let calendarQuery = "query calendar_dailyCalendarEvents($dates: [PartnersCalendar_PlainDate!]!, $locationIds: [ID!]!, $bookableAssets: [PartnersCalendar_BookableAssetInput!]!, $filters: PartnersCalendar_CalendarEventFiltersInput, $options: PartnersCalendar_CalendarEventOptionsInput) { dailyCalendarEvents: PartnersCalendar_dailyCalendarEvents(dates: $dates, locationIds: $locationIds, bookableAssets: $bookableAssets, filters: $filters, options: $options) { date bookableAsset { ... on PartnersCalendar_BookableEmployee { id } } events { start end details { __typename ... on PartnersCalendar_CalendarBookingEvent { bookingId appointmentId systemStatus service { name } customer { id fullName email contactNumber } } } } } }"

    // Reads Fresha's calendar (bookings, cancelled ones included) for the given days and staff.
    // Returns the "dailyCalendarEvents" list as JSON, or nil when it could not be read.
    func calendarRaw(dates: [String], locationId: String, employeeIds: [String]) async -> (data: Data?, needsLogin: Bool) {
        do {
            let cookie = await cookieHeader()
            if cookie.isEmpty { return (nil, true) }
            var comps = URLComponents(string: "https://partners-api-gateway.fresha.com/graphql")!
            comps.queryItems = [URLQueryItem(name: "_query", value: "calendar_dailyCalendarEvents"), URLQueryItem(name: "_client_platform", value: "web"), URLQueryItem(name: "_client_version", value: clientVersion)]
            var req = URLRequest(url: comps.url!)
            req.httpMethod = "POST"
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
            req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://partners.fresha.com", forHTTPHeaderField: "Origin")
            req.setValue("https://partners.fresha.com/", forHTTPHeaderField: "Referer")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            let vars: [String: Any] = [
                "bookableAssets": employeeIds.map { ["id": $0, "type": "EMPLOYEE"] },
                "clientCapabilities": ["EVENTUALLY_CONSISTENT_READS"],
                "dates": dates,
                "filters": ["eventTypes": ["BOOKING"], "includeCancelled": true],
                "locationIds": [locationId],
                "options": ["allowStaleData": true, "groupByBookableAsset": true],
                "visibilityFilters": [String: Any]()
            ]
            let varsJSON = String(data: try JSONSerialization.data(withJSONObject: vars), encoding: .utf8) ?? "{}"
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            func enc(_ x: String) -> String { x.addingPercentEncoding(withAllowedCharacters: allowed) ?? x }
            let body = "operationName=calendar_dailyCalendarEvents&query=\(enc(calendarQuery))&variables=\(enc(varsJSON))"
            req.httpBody = body.data(using: .utf8)
            let (data, resp) = try await session.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 { return (nil, true) }
            guard status == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return (nil, false) }
            if json["errors"] != nil { return (nil, false) }
            guard let list = (json["data"] as? [String: Any])?["dailyCalendarEvents"] else { return (nil, false) }
            return (try JSONSerialization.data(withJSONObject: ["calendar": list]), false)
        } catch {
            return (nil, false)
        }
    }

    private func hhmmss(_ s: String?) -> String { String((s ?? "").prefix(5)) + ":00" }

    func run(_ job: Job) async -> JobResult {
        do {
            if job.action == "add" {
                guard let emp = job.employee_id, let loc = job.location_id else { return JobResult(ok: false, error: "staff not mapped") }
                let input: [String: Any] = [
                    "allowOnlineBooking": false,
                    "blockedTimeGroup": ["employeeIds": [String(emp)]],
                    "employeeId": String(emp),
                    "endDate": job.block_date,
                    "endTime": hhmmss(job.end_time),
                    "locationId": String(loc),
                    "note": "",
                    "repeat": ["type": "NONE"],
                    "startDate": job.block_date,
                    "startTime": hhmmss(job.start_time),
                    "title": ""
                ]
                let json = try await graphql("createBlockedTime", query: "mutation createBlockedTime($input: BlockedTimeInput!) {\n  createBlockedTime(input: $input) {\n    id\n    __typename\n  }\n}", variables: ["input": input])
                let id = ((json["data"] as? [String: Any])?["createBlockedTime"] as? [String: Any])?["id"] as? String
                return JobResult(ok: true, appointmentId: id.flatMap { Int($0) })
            }
            if job.action == "cancel" {
                guard let id = job.fresha_block_id else { return JobResult(ok: true, note: "nothing of ours to remove") }
                _ = try await graphql("deleteBlockedTime", query: "mutation deleteBlockedTime($id: IID!) {\n  deleteBlockedTime(id: $id) {\n    id\n    __typename\n  }\n}", variables: ["id": String(id)])
                return JobResult(ok: true)
            }
            return JobResult(ok: false, error: "unknown action")
        } catch is LoginNeeded {
            return JobResult(ok: false, needsLogin: true)
        } catch let e as Failed {
            return JobResult(ok: false, error: e.text)
        } catch {
            return JobResult(ok: false, error: String(describing: error).prefix(150).description)
        }
    }
}
