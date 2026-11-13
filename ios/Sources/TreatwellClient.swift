import Foundation
import WebKit

struct Job: Decodable {
    let id: Int
    let action: String
    let block_date: String
    let start_time: String
    let end_time: String?
    let employee_id: Int?
    let service_id: Int?
    let sku_id: Int?
    let treatwell_appointment_id: Int?
}

struct JobResult {
    var ok: Bool
    var appointmentId: Int? = nil
    var error: String? = nil
    var note: String? = nil
    var needsLogin = false
}

// Talks to Treatwell Connect using the login the person made inside this app (cookies copied from the web view).
final class TreatwellClient {
    private let base = "https://connect.treatwell.co.uk/api/venue/384794"
    private let session: URLSession

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
        return cookies.filter { $0.domain.contains("treatwell") }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> (Int, Data) {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.setValue(await cookieHeader(), forHTTPHeaderField: "Cookie")
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://connect.treatwell.co.uk", forHTTPHeaderField: "Origin")
        req.setValue("https://connect.treatwell.co.uk/", forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        if let body = body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await session.data(for: req)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func hhmm(_ s: String?) -> String { String((s ?? "").prefix(5)) }

    private func findIds(job: Job) async throws -> [Int] {
        let d = job.block_date
        let path = "/calendar.json?date-from=\(d)&date-to=\(d)&include=appointments%2Cblocks&appointment-status-codes=CR%2CCN%2CNS%2CCP"
        let (status, data) = try await request("GET", path)
        if status == 401 || status == 403 { throw LoginNeeded() }
        if status != 200 { throw SimpleError("calendar HTTP \(status)") }
        let json = try JSONSerialization.jsonObject(with: data)
        var ids = Set<Int>()
        func walk(_ o: Any) {
            if let a = o as? [Any] { a.forEach(walk) }
            else if let m = o as? [String: Any] {
                let id = (m["appointmentId"] as? Int) ?? (m["id"] as? Int)
                if let id = id, (m["employeeId"] as? Int) == job.employee_id, hhmm(m["startTime"] as? String) == hhmm(job.start_time) { ids.insert(id) }
                m.values.forEach(walk)
            }
        }
        walk(json)
        return Array(ids)
    }

    // The raw calendar for a date range, exactly as Treatwell returns it. SyncHub works out what is new.
    func calendarRaw(from: String, to: String) async -> Data? {
        let path = "/calendar.json?date-from=\(from)&date-to=\(to)&include=appointments%2Cblocks&appointment-status-codes=CR%2CCN%2CNS%2CCP"
        guard let (status, data) = try? await request("GET", path), status == 200 else { return nil }
        return data
    }

    struct LoginNeeded: Error {}
    struct SimpleError: Error { let text: String; init(_ t: String) { text = t } }

    func run(_ job: Job) async -> JobResult {
        do {
            if job.action == "add" {
                guard let emp = job.employee_id, let svc = job.service_id, let sku = job.sku_id else { return JobResult(ok: false, error: "staff not mapped") }
                if !(try await findIds(job: job)).isEmpty { return JobResult(ok: true, note: "something already there") }
                let body: [String: Any] = ["appointments": [["appointmentDate": job.block_date, "employeeId": emp, "startTime": hhmm(job.start_time), "serviceId": svc, "skus": [["skuId": sku]], "notes": "", "platform": "DESKTOP", "endTime": hhmm(job.end_time)]], "appointmentGroups": []]
                let (status, _) = try await request("POST", "/appointments", body: body)
                if status == 401 || status == 403 { return JobResult(ok: false, needsLogin: true) }
                if !(200..<300).contains(status) { return JobResult(ok: false, error: "create HTTP \(status)") }
                let after = try await findIds(job: job)
                return after.count == 1 ? JobResult(ok: true, appointmentId: after[0]) : JobResult(ok: true)
            }
            if job.action == "cancel" {
                guard let id = job.treatwell_appointment_id else { return JobResult(ok: true, note: "nothing of ours to cancel") }
                let body: [String: Any] = ["notifyConsumer": false, "platform": "DESKTOP", "includeFutureRecurrences": false]
                let (status, _) = try await request("POST", "/appointment/\(id)/cancel", body: body)
                if status == 401 || status == 403 { return JobResult(ok: false, needsLogin: true) }
                return (200..<300).contains(status) ? JobResult(ok: true) : JobResult(ok: false, error: "cancel HTTP \(status)")
            }
            return JobResult(ok: false, error: "unknown action")
        } catch is LoginNeeded {
            return JobResult(ok: false, needsLogin: true)
        } catch let e as SimpleError {
            return JobResult(ok: false, error: e.text)
        } catch {
            return JobResult(ok: false, error: String(describing: error).prefix(150).description)
        }
    }
}
