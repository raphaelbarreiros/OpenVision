// OpenVision - HermesSettingsView.swift
// Hermes Agent backend configuration: the API server address and key, or a sign-in to the Hermes
// web UI with its username and password.

import SwiftUI

struct HermesSettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var authMode = SettingsManager.shared.settings.hermesAuthMode
    @State private var serverURL = SettingsManager.shared.settings.hermesServerURL
    @State private var apiKey = SettingsManager.shared.settings.hermesAPIKey
    @State private var dashboardURL = SettingsManager.shared.settings.hermesDashboardURL
    @State private var isSignedIn = HermesSettingsView.signedIn(to: SettingsManager.shared.settings.hermesDashboardURL)
    @State private var isSigningIn = false
    @State private var signInError: String?

    private enum TestState: Equatable {
        case idle, testing
        case ok(String)
        case failed(String)
    }
    @State private var testState: TestState = .idle

    var body: some View {
        Form {
            Section {
                Picker("Connect With", selection: $authMode) {
                    ForEach(HermesAuthMode.allCases) { mode in
                        ConnectMethodRow(title: mode.displayName, summary: mode.summary, icon: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Connect With")
            }

            switch authMode {
            case .apiKey: apiKeySections
            case .password: passwordSections
            }

            Section {
                Link(destination: URL(string: "https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/api-server.md")!) {
                    HStack {
                        Text("Hermes API Server Guide")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
                    }
                }
                Link(destination: URL(string: "https://github.com/NousResearch/hermes-agent/blob/main/website/docs/user-guide/features/web-dashboard.md")!) {
                    HStack {
                        Text("Hermes Web UI Guide")
                        Spacer()
                        Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
                    }
                }
            } header: {
                Text("Help")
            } footer: {
                Text("Hermes answers with its own tools, memory and skills; replies are spoken briefly.")
            }
        }
        .navigationTitle("Hermes")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { saveSettings() }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { saveSettings(); dismiss() }
            }
        }
    }

    // MARK: - API key

    @ViewBuilder
    private var apiKeySections: some View {
        Section {
            TextField("https://hermes.example.com", text: $serverURL)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .onChange(of: serverURL) { _, _ in testState = .idle }
        } header: {
            Text("Server")
        } footer: {
            if HermesService.isUnencryptedRemote(serverURL) {
                Label("This address isn't encrypted. Your API key would cross the internet in plain text, and it gives access to Hermes' tools, including the terminal. Use https or a Tailscale address.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.caption)
            } else {
                Text("Your Hermes API server. Add /p/<profile> for a named profile.")
            }
        }

        Section {
            SecureField("API_SERVER_KEY", text: $apiKey)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .onChange(of: apiKey) { _, _ in testState = .idle }
        } header: {
            Text("API Key")
        } footer: {
            Text("The API_SERVER_KEY from your server's ~/.hermes/.env.")
        }

        Section {
            Button {
                Task { await testConnection() }
            } label: {
                HStack {
                    Text("Test Connection")
                    Spacer()
                    if testState == .testing { ProgressView() }
                }
            }
            .disabled(testState == .testing || serverURL.isEmpty || apiKey.isEmpty)
        } footer: {
            switch testState {
            case .ok(let model):
                Label("Connected to \(model)", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.caption)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.caption)
            case .idle, .testing:
                EmptyView()
            }
        }

    }

    // MARK: - Username & password

    @ViewBuilder
    private var passwordSections: some View {
        Section {
            TextField("https://hermes.example.com", text: $dashboardURL)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(isSignedIn)
        } header: {
            Text("Web UI Address")
        } footer: {
            if HermesService.isUnencryptedRemote(dashboardURL) {
                Label("This address isn't encrypted, so signing in is turned off. Use https or a Tailscale address: Hermes' web UI login is meant for a trusted network or VPN.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.caption)
            } else {
                Text("The address of your Hermes web UI (hermes dashboard). Sign out to change it.")
            }
        }

        Section {
            if isSignedIn {
                Label("Signed in to Hermes", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Button("Sign Out", role: .destructive) { signOut() }
            } else {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Text("Sign in to Hermes")
                        Spacer()
                        if isSigningIn { ProgressView() }
                    }
                }
                .disabled(isSigningIn || HermesDashboard.base(from: dashboardURL) == nil)
            }
        } header: {
            Text("Account")
        } footer: {
            if let signInError {
                Label(signInError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.caption)
            } else {
                Text("You sign in on your Hermes login page with its username and password; OpenVision only keeps the tokens Hermes issues, in the Keychain. Approvals Hermes asks for are read out, and you answer yes or no. Requests for passwords or secrets are always declined.")
            }
        }
    }

    private static func signedIn(to dashboardURL: String) -> Bool {
        guard let base = HermesDashboard.base(from: dashboardURL) else { return false }
        return OAuthTokenStore.shared.isSignedIn(HermesDashboard.provider(base: base))
    }

    private func signIn() async {
        guard let base = HermesDashboard.base(from: dashboardURL) else { return }
        saveSettings()
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            try await HermesService.checkAppSignIn(base: base)
            try await OAuthSignIn.signIn(HermesDashboard.provider(base: base))
            isSignedIn = true
        } catch OAuthError.cancelled {
            // User closed the sheet.
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func signOut() {
        if let base = HermesDashboard.base(from: dashboardURL) {
            OAuthTokenStore.shared.signOut(HermesDashboard.provider(base: base))
        }
        HermesGatewayClient.shared.disconnect()
        settingsManager.settings.hermesSessions = [:]
        isSignedIn = false
    }

    private func testConnection() async {
        saveSettings()
        testState = .testing
        do {
            let info = try await HermesService.testConnection(serverURL: serverURL, apiKey: apiKey)
            testState = .ok(info.model)
        } catch {
            testState = .failed(error.localizedDescription)
        }
    }

    private func saveSettings() {
        settingsManager.settings.hermesAuthMode = authMode
        settingsManager.settings.hermesDashboardURL = dashboardURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.settings.hermesServerURL = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.settings.hermesAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.saveNow()
    }
}

#Preview {
    NavigationStack {
        HermesSettingsView().environmentObject(SettingsManager.shared)
    }
}
