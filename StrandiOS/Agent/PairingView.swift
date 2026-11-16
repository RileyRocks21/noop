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
