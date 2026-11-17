#if os(iOS)
import SwiftUI
import StrandDesign

// MARK: - Pairing screen
//
// One-time link to the noop-agent backend: server URL + the 6-digit code from
// `docker compose exec api npm run pair` (valid 10 minutes). Success stores the device token in
// the Keychain (AgentConfig) and every screen unlocks. Shown in place of the agent screens
// whenever `AgentConfig.isPaired` is false — which a 401 anywhere also forces.

struct PairingView: View {
    @ObservedObject private var config = AgentConfig.shared
    @State private var code = ""
    @State private var isPairing = false
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var testResult: String?
    @State private var testOK = false

    var body: some View {
        ScreenScaffold(title: "Pair with your server",
                       subtitle: "One-time setup",
                       topBackground: liquidScaffoldSky()) {
            NoopCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("SERVER").strandOverline()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Server URL")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        TextField("http://riley-pc.tailnet-name.ts.net:8080", text: $config.serverURL)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(StrandPalette.surfaceInset))

                        // Test the URL BEFORE pairing: /health needs no auth and no code, so a
                        // reachability problem is diagnosable without burning a 10-minute code.
                        Button {
                            test()
                        } label: {
                            HStack(spacing: 6) {
                                if isTesting { ProgressView().controlSize(.small) }
                                Text(isTesting ? "Testing…" : "Test connection")
                                    .font(StrandFont.subhead)
                            }
                            .foregroundStyle(StrandPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(isTesting || config.serverURL.trimmingCharacters(in: .whitespaces).isEmpty)

                        if let testResult {
                            Text(testResult)
                                .font(StrandFont.footnote)
                                .foregroundStyle(testOK ? StrandPalette.recovery100 : StrandPalette.metricRose)
                                .textSelection(.enabled)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pairing code")
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        TextField("6-digit code", text: $code)
                            .textFieldStyle(.plain)
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .keyboardType(.numberPad)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(StrandPalette.surfaceInset))
                        Text("On the server, run: docker compose exec api npm run pair — the code is valid for 10 minutes.")
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(StrandFont.footnote).foregroundStyle(StrandPalette.metricRose)
                    }

                    Button {
                        pair()
                    } label: {
                        HStack {
                            if isPairing { ProgressView().tint(StrandPalette.surfaceBase) }
                            Text(isPairing ? "Pairing…" : "Pair")
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.surfaceBase)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Capsule().fill(StrandPalette.accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canPair)
                    .opacity(canPair ? 1 : 0.4)
                }
            }
        }
    }

    private var canPair: Bool {
        !config.serverURL.trimmingCharacters(in: .whitespaces).isEmpty
            && code.trimmingCharacters(in: .whitespaces).count == 6
            && !isPairing
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

    private func pair() {
        isPairing = true
        errorMessage = nil
        struct Body: Encodable { let code: String; let deviceName: String; let platform: String }
        let body = Body(code: code.trimmingCharacters(in: .whitespaces),
                        deviceName: UIDevice.current.name,
                        platform: "ios")
        Task {
            defer { isPairing = false }
            do {
                let response: AgentPairResponse = try await AgentAPI.shared.post("/auth/pair", body: body)
                config.didPair(deviceId: response.deviceId, token: response.token)
            } catch {
                errorMessage = NutritionStore.describe(error)
            }
        }
    }
}
#endif
