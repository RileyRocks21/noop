#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Server settings (Settings → Server)
//
// The handoff's config MUSTs: editable server URL, a "Test connection" button that calls
// GET /health (and surfaces the backend version), and unpair. Plain http:// is allowed for
// .ts.net hosts and LAN IPs — the ATS exceptions live in project.yml.

struct ServerSettingsView: View {
    @ObservedObject private var config = AgentConfig.shared
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testOK = false
    @State private var showUnpairConfirm = false

    var body: some View {
        Form {
            Section {
                TextField("http://riley-pc.tailnet-name.ts.net:8080", text: $config.serverURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    test()
                } label: {
                    HStack {
                        Label("Test connection", systemImage: "network")
                        if isTesting { Spacer(); ProgressView() }
                    }
                }
                .disabled(isTesting || config.serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
                if let testResult {
                    Label(testResult, systemImage: testOK ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(testOK ? .green : .red)
                        .font(.footnote)
                }
            } header: {
                Text("Server")
            } footer: {
                Text("Plain http:// is allowed for .ts.net hosts and private LAN addresses (Tailscale encrypts the link).")
            }

            if config.isPaired {
                Section("Pairing") {
                    LabeledContent("Status", value: "Paired")
                    if let deviceId = config.deviceId {
                        LabeledContent("Device", value: deviceId)
                            .font(.footnote)
                    }
                    if let version = config.backendVersion {
                        LabeledContent("Backend version", value: version)
                    }
                    Button("Unpair", role: .destructive) { showUnpairConfirm = true }
                }
            }
        }
        .navigationTitle("Server")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Unpair from this server?", isPresented: $showUnpairConfirm,
                            titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { config.unpair() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The device token is deleted from this iPhone. Pair again with a fresh 6-digit code to reconnect.")
        }
    }

    private func test() {
        isTesting = true
        testResult = nil
        Task {
            defer { isTesting = false }
            do {
                // /health is unauthenticated per the contract.
                let health: AgentHealthResponse = try await AgentAPI.shared.get("/health")
                if health.ok == true {
                    config.backendVersion = health.version
                    testOK = true
                    testResult = "Connected — backend \(health.version ?? "version unknown")"
                } else {
                    testOK = false
                    testResult = "Server answered but reports not OK."
                }
            } catch {
                testOK = false
                testResult = NutritionStore.describe(error)
            }
        }
    }
}
#endif
