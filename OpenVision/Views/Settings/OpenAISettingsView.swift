// OpenVision - OpenAISettingsView.swift
// OpenAI (and OpenAI-compatible) backend configuration: API key, or ChatGPT subscription sign-in.

import SwiftUI

struct OpenAISettingsView: View {
    @EnvironmentObject var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss

    @State private var authMode: OpenAIAuthMode = .apiKey
    @State private var apiKey: String = ""
    @State private var model: String = "gpt-4o-mini"
    @State private var baseURL: String = "https://api.openai.com/v1"

    // ChatGPT subscription
    @State private var subscriptionModel: String = ChatGPTSubscription.defaultModel
    @State private var isSignedIn = OAuthTokenStore.shared.isSignedIn(ChatGPTSubscription.provider)
    @State private var isSigningIn = false
    @State private var subscriptionModels: [ChatGPTSubscription.Model] = []
    @State private var subscriptionError: String?

    var body: some View {
        Form {
            Section {
                Picker("Connect With", selection: $authMode) {
                    ForEach(OpenAIAuthMode.allCases) { mode in
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
            case .chatGPTSubscription: subscriptionSections
            }
        }
        .navigationTitle("OpenAI")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            authMode = settingsManager.settings.openAIAuthMode
            apiKey = settingsManager.settings.openAIAPIKey
            model = settingsManager.settings.openAIModel
            baseURL = settingsManager.settings.openAIBaseURL
            subscriptionModel = settingsManager.settings.openAISubscriptionModel
            isSignedIn = OAuthTokenStore.shared.isSignedIn(ChatGPTSubscription.provider)
        }
        .task(id: isSignedIn) { await loadSubscriptionModels() }
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
        // API Key
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text("API Key")
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("sk-…", text: $apiKey)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            }
        } header: {
            Text("Authentication")
        } footer: {
            if apiKey.isEmpty {
                Label("Required for OpenAI mode", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.caption)
            } else {
                Label("API key configured", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green).font(.caption)
            }
        }

        // Model
        Section {
            TextField("Model", text: $model)
                .autocapitalization(.none)
                .autocorrectionDisabled()
        } header: {
            Text("Model")
        } footer: {
            Text("e.g. gpt-4o-mini (cheap, supports vision), gpt-4o, or any model your endpoint serves.")
        }

        // Endpoint (for OpenAI-compatible servers)
        Section {
            TextField("Base URL", text: $baseURL)
                .autocapitalization(.none)
                .autocorrectionDisabled()
                .keyboardType(.URL)
        } header: {
            Text("Endpoint")
        } footer: {
            Text("Default is OpenAI. Point this at any OpenAI-compatible API (OpenRouter, a local server, etc.). No trailing slash.")
        }

        // Help
        Section {
            Link(destination: URL(string: "https://platform.openai.com/api-keys")!) {
                HStack {
                    Text("Get API Key")
                    Spacer()
                    Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Help")
        } footer: {
            Text("OpenAI is a cloud backend for text and vision (photos). Useful for verifying the cloud command + camera path.")
        }
    }

    // MARK: - ChatGPT subscription

    @ViewBuilder
    private var subscriptionSections: some View {
        Section {
            if isSignedIn {
                Label("Signed in to ChatGPT", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Button("Sign Out", role: .destructive) {
                    OAuthTokenStore.shared.signOut(ChatGPTSubscription.provider)
                    isSignedIn = false
                    subscriptionModels = []
                }
            } else {
                Button {
                    Task { await signIn() }
                } label: {
                    HStack {
                        Text("Sign in with ChatGPT")
                        Spacer()
                        if isSigningIn { ProgressView() }
                    }
                }
                .disabled(isSigningIn)
            }
        } header: {
            Text("Account")
        } footer: {
            if let subscriptionError {
                Label(subscriptionError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange).font(.caption)
            } else {
                Text("Signs in the same way as the Codex CLI. This isn't an official OpenAI API, so it can change or stop working.")
            }
        }

        Section {
            if subscriptionModels.isEmpty {
                TextField("Model", text: $subscriptionModel)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
            } else {
                Picker("Model", selection: $subscriptionModel) {
                    ForEach(modelChoices) { model in
                        Text(model.displayName).tag(model.slug)
                    }
                }
            }
        } header: {
            Text("Model")
        } footer: {
            Text("Models available on your plan. Smaller models answer faster, which matters for voice.")
        }
    }

    /// The live list, plus the saved model if the server no longer lists it (so the Picker
    /// always has a matching tag).
    private var modelChoices: [ChatGPTSubscription.Model] {
        if subscriptionModels.contains(where: { $0.slug == subscriptionModel }) { return subscriptionModels }
        return [ChatGPTSubscription.Model(slug: subscriptionModel, displayName: subscriptionModel)] + subscriptionModels
    }

    private func signIn() async {
        isSigningIn = true
        subscriptionError = nil
        defer { isSigningIn = false }
        do {
            try await OAuthSignIn.signIn(ChatGPTSubscription.provider)
            isSignedIn = true
        } catch OAuthError.cancelled {
            // User closed the sheet — nothing to report.
        } catch {
            subscriptionError = error.localizedDescription
        }
    }

    private func loadSubscriptionModels() async {
        guard isSignedIn else { return }
        do {
            subscriptionModels = try await ChatGPTSubscription.fetchModels()
            subscriptionError = nil
        } catch is CancellationError {
            // SwiftUI restarted the task (e.g. the sign-in state changed) — not a failure.
        } catch let error as URLError where error.code == .cancelled {
            // Same, surfaced by URLSession.
        } catch {
            subscriptionError = error.localizedDescription
            isSignedIn = OAuthTokenStore.shared.isSignedIn(ChatGPTSubscription.provider)
        }
    }

    private func saveSettings() {
        settingsManager.settings.openAIAuthMode = authMode
        settingsManager.settings.openAIAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.settings.openAIModel = trimmedModel.isEmpty ? "gpt-4o-mini" : trimmedModel
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.hasSuffix("/") { url.removeLast() }
        settingsManager.settings.openAIBaseURL = url.isEmpty ? "https://api.openai.com/v1" : url
        let trimmedSubscriptionModel = subscriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        settingsManager.settings.openAISubscriptionModel = trimmedSubscriptionModel.isEmpty
            ? ChatGPTSubscription.defaultModel : trimmedSubscriptionModel
        settingsManager.saveNow()
    }
}

#Preview {
    NavigationStack {
        OpenAISettingsView().environmentObject(SettingsManager.shared)
    }
}
