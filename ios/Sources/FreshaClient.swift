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
