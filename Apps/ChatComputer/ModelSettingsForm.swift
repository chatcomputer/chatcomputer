import ChatCore
import ModelProxy
import SwiftUI

/// Choose a vendor, protocol, endpoint and model, enter the key, and test the connection.
/// Used in the last onboarding step and in Settings.
struct ModelSettingsForm: View {
    @Environment(AppModel.self) private var model
    /// Settings lists every saved key with a way to remove it; onboarding doesn't.
    var showsSavedKeys = false
    /// Called after a successful save.
    var onSaved: () -> Void = {}

    @State private var settings = ModelSettings.default
    @State private var customModel = false
    @State private var apiKey = ""
    @State private var savedKeySuffix: String?
    @State private var status: Status = .idle
    @State private var savedKeys: [(provider: ProviderPreset, suffix: String)] = []

    enum Status: Equatable {
        case idle
        case testing
        case ok(String)
        case failed(String)
    }

    private var provider: ProviderPreset? { ModelCatalog.provider(settings.providerID) }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: Binding(get: { settings.providerID }, set: selectProvider)) {
                    ForEach(ModelCatalog.providers) { Text($0.name).tag($0.id) }
                }
                if let provider, provider.protocols.count > 1 {
                    Picker("Protocol", selection: Binding(get: { settings.protocolKind }, set: selectProtocol)) {
                        ForEach(provider.protocols) { Text($0.displayName).tag($0) }
                    }
                }
                if let provider, !provider.models.isEmpty, !customModel {
                    Picker("Model", selection: Binding(get: { settings.model }, set: selectModel)) {
                        ForEach(provider.models) { preset in
                            Text(preset.note.isEmpty ? preset.name : "\(preset.name) — \(preset.note)").tag(preset.id)
                        }
                        Divider()
                        Text("Other model…").tag(Self.otherTag)
                    }
                } else {
                    LabeledContent("Model") {
                        HStack {
                            TextField("Model ID", text: $settings.model, prompt: Text("model-id"))
                                .labelsHidden()
                                .font(.body.monospaced())
                                .multilineTextAlignment(.trailing)
                            if let provider, !provider.models.isEmpty {
                                Button("List") {
                                    customModel = false
                                    settings.model = provider.models.first?.id ?? ""
                                }
                                .help("Choose from the models this provider offers")
                            }
                        }
                    }
                }
            } header: {
                Text("Provider")
            } footer: {
                if let notes = provider?.notes, !notes.isEmpty { Text(notes) }
            }

            Section("Connection") {
                LabeledContent("Endpoint") {
                    TextField("Endpoint", text: $settings.baseURL, prompt: Text("https://"))
                        .labelsHidden()
                        .font(.body.monospaced())
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("API key") {
                    SecureField("API key", text: $apiKey,
                                prompt: Text(savedKeySuffix.map { "Saved, ends in …\($0)" } ?? "Paste your key"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                }
                if let page = provider?.keyPage, !page.isEmpty, let url = URL(string: page) {
                    LabeledContent("Don't have a key?") { Link("Get one from \(provider?.name ?? "the provider")", destination: url) }
                }
            }

            Section {
                HStack {
                    statusView
                    Spacer()
                    Button(status == .testing ? "Testing…" : "Save and Test") { Task { await saveAndTest() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(status == .testing || settings.model.isEmpty || (apiKey.isEmpty && savedKeySuffix == nil))
                }
            } footer: {
                Text(footnote)
            }

            if showsSavedKeys, !savedKeys.isEmpty {
                Section {
                    ForEach(savedKeys, id: \.provider.id) { entry in
                        LabeledContent {
                            Button("Remove", role: .destructive) { removeKey(for: entry.provider) }
                        } label: {
                            Text(entry.provider.name)
                            Text("Ends in …\(entry.suffix)" + (entry.provider.id == model.modelSettings.providerID ? " · in use" : ""))
                        }
                    }
                } header: {
                    Text("Saved Keys")
                } footer: {
                    Text("Each provider's key is kept separately, in a file only your account can read. Removing one doesn't revoke it; do that on the provider's site.")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
    }

    private static let otherTag = "__other__"

    @ViewBuilder private var statusView: some View {
        switch status {
        case .testing: ProgressView().controlSize(.small)
        case .idle:
            if model.modelSettings == settings, savedKeySuffix != nil {
                Label("In use", systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout)
            }
        case .ok(let message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        }
    }

    private var footnote: String {
        var parts = ["Save and Test sends a short request to check the key and the model. While a task runs, screenshots and text from the virtual Mac go to this provider."]
        if provider?.isClaude == false {
            parts.append("The model must accept images and call tools.")
        }
        return parts.joined(separator: " ")
    }

    // MARK: Actions

    private func load() {
        settings = model.modelSettings
        customModel = !(provider?.models.contains { $0.id == settings.model } ?? false)
        refreshSavedKey()
    }

    private func refreshSavedKey() {
        savedKeySuffix = (try? model.secrets.read(settings.secretAccount))?.suffix(4).description
        savedKeys = ModelCatalog.providers.compactMap { preset in
            guard let key = try? model.secrets.read(ModelSettings.preset(preset).secretAccount), !key.isEmpty else { return nil }
            return (preset, String(key.suffix(4)))
        }
    }

    private func removeKey(for preset: ProviderPreset) {
        try? model.secrets.delete(ModelSettings.preset(preset).secretAccount)
        if preset.id == settings.providerID { status = .idle }
        refreshSavedKey()
    }

    private func selectProvider(_ id: String) {
        guard let preset = ModelCatalog.provider(id) else { return }
        settings = ModelSettings.preset(preset)
        customModel = preset.models.isEmpty
        apiKey = ""
        status = .idle
        refreshSavedKey()
    }

    private func selectProtocol(_ kind: ModelProtocol) {
        settings.protocolKind = kind
        settings.baseURL = provider?.endpoints[kind] ?? settings.baseURL
        status = .idle
    }

    private func selectModel(_ id: String) {
        if id == Self.otherTag {
            customModel = true
            settings.model = ""
        } else {
            settings.model = id
        }
        status = .idle
    }

    private func saveAndTest() async {
        status = .testing
        do {
            if !apiKey.isEmpty {
                try model.secrets.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: settings.secretAccount)
                apiKey = ""
                refreshSavedKey()
            }
            let client = try model.makeModelClient(for: settings)
            switch await ConnectionTest.run(client) {
            case .success(let message):
                model.saveModelSettings(settings)
                status = .ok(message)
                onSaved()
            case .failure(let error):
                status = .failed(Self.describe(error))
            }
        } catch let error as ModelError {
            status = .failed(Self.describe(error))
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    static func describe(_ error: ModelError) -> String {
        switch error {
        case .missingAPIKey: "Enter an API key."
        case .authentication(let message): "The provider rejected the key: \(message)"
        case .billing(let message): "The key works, but the account has no credit left: \(message)"
        case .rateLimited: "Rate limited by the provider. Try again shortly."
        case .overloaded: "The provider is overloaded. Try again shortly."
        case .badRequest(let message): "The provider rejected the request: \(message)"
        case .server(let status, let message): "Provider error \(status): \(message)"
        case .refused: "The model refused the test request."
        case .network(let message): "Could not reach the endpoint: \(message)"
        case .malformedResponse: "The endpoint answered, but not in the expected format. Check the protocol and endpoint."
        }
    }
}
