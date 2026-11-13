import Foundation
import SwiftUI

@MainActor
final class HelperEngine: ObservableObject {
    static let shared = HelperEngine()

    @Published var key: String = UserDefaults.standard.string(forKey: "key") ?? ""
    @Published var running: Bool = UserDefaults.standard.bool(forKey: "running")
    @Published var status: String = "Not started."
    @Published var needsLogin = false
    @Published var lastOk: Date? = nil

    private let keepAlive = KeepAlive()
    private let client = TreatwellClient()
    private var loop: Task<Void, Never>? = nil
    private var tick = 0
    private var learned = false

    init() { if running && !key.isEmpty { start() } }

    func saveKey(_ k: String) {
        key = k.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(key, forKey: "key")
    }

    func start() {
        guard !key.isEmpty else { status = "Paste your SyncHub key first."; return }
        running = true
        UserDefaults.standard.set(true, forKey: "running")
        keepAlive.start()
        UIApplication.shared.isIdleTimerDisabled = false
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: Config.pollSeconds * 1_000_000_000)
            }
        }
    }

    func stop() {
        running = false
        UserDefaults.standard.set(false, forKey: "running")
        loop?.cancel()
        status = "Stopped."
    }

    private func headers() -> [String: String] {
        ["Authorization": "Bearer \(key)", "x-helper-version": Config.version]
    }

    private func pollOnce() async {
        // Make sure the silent sound is still playing (it is what keeps the app awake).
        if !keepAlive.isPlaying { keepAlive.start() }
        do {
            var req = URLRequest(url: URL(string: Config.synchub + "/api/helper/jobs")!)
            req.timeoutInterval = 20
            req.cachePolicy = .reloadIgnoringLocalCacheData
            headers().forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { status = "SyncHub did not accept the key. Make a new one."; return }
            if code != 200 { status = "SyncHub error \(code)"; return }
            struct Reply: Decodable { let jobs: [Job] }
            let jobs = try JSONDecoder().decode(Reply.self, from: data).jobs
            var done = 0
            for job in jobs {
                let t0 = Date()
                let out = await client.run(job)
                if out.needsLogin {
                    // Don't tell SyncHub it failed: the job stays waiting until the person logs in again.
                    needsLogin = true
                    status = "Log in to Treatwell inside this app."
                    return
                }
                needsLogin = false
                await report(job: job, out: out, ms: Int(Date().timeIntervalSince(t0) * 1000))
                done += 1
            }
            lastOk = Date()
            tick += 1
            if tick % 6 == 1 { await uploadCalendar() }
            status = done > 0 ? "Did \(done) job(s)." : "OK, nothing to do."
        } catch {
            status = "Waiting for internet…"
        }
    }

    // Sends Treatwell's own calendar (next 30 days) to SyncHub so bookings made on Treatwell appear in SyncHub.
    private func uploadCalendar() async {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_GB_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/London")
        f.dateFormat = "yyyy-MM-dd"
        let from = f.string(from: Date())
        let to = f.string(from: Date().addingTimeInterval(30 * 86400))
        guard let data = await client.calendarRaw(from: from, to: to) else { return }
        var req = URLRequest(url: URL(string: Config.synchub + "/api/helper/calendar")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        headers().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !learned { req.setValue("1", forHTTPHeaderField: "x-helper-learn") }
        req.httpBody = data
        if let (_, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200 { learned = true }
    }

    private func report(job: Job, out: JobResult, ms: Int) async {
        var body: [String: Any] = ["ok": out.ok, "ms": ms]
        if let id = out.appointmentId { body["appointmentId"] = id }
        if let e = out.error { body["error"] = e }
        if let n = out.note { body["note"] = n }
        var req = URLRequest(url: URL(string: Config.synchub + "/api/helper/jobs/\(job.id)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        headers().forEach { req.setValue($1, forHTTPHeaderField: $0) }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
}
