import SwiftUI
import WebKit

struct TreatwellWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.customUserAgent = Config.userAgent
        w.load(URLRequest(url: URL(string: Config.treatwell)!))
        return w
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct ContentView: View {
    @EnvironmentObject var engine: HelperEngine
    @State private var keyText = ""
    @State private var showLogin = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("1. SyncHub key")) {
                    TextField("Paste key from SyncHub", text: $keyText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save key") { engine.saveKey(keyText) }
                    if !engine.key.isEmpty { Text("Key saved ✓").foregroundColor(.green) }
                }
                Section(header: Text("2. Treatwell")) {
                    Button("Log in to Treatwell") { showLogin = true }
                    if engine.needsLogin { Text("Please log in again.").foregroundColor(.red) }
                }
                Section(header: Text("3. Run")) {
                    Toggle("Helper ON", isOn: Binding(get: { engine.running }, set: { $0 ? engine.start() : engine.stop() }))
                    Text(engine.status)
                    if let d = engine.lastOk { Text("Last check: \(d.formatted(date: .omitted, time: .standard))").font(.footnote) }
                    Text("Keep this app open once, then lock the phone. Don't swipe it away.").font(.footnote).foregroundColor(.secondary)
                }
            }
            .navigationTitle("SyncHub Helper")
            .sheet(isPresented: $showLogin) {
                NavigationView {
                    TreatwellWebView().navigationTitle("Treatwell")
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showLogin = false } } }
                }
            }
        }
        .navigationViewStyle(.stack)
        .onAppear { keyText = engine.key }
    }
}
