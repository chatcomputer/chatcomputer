import ChatCore
import ModelProxy
import SwiftUI

/// Choose a vendor, protocol, endpoint and model, enter the key, and test the connection.
/// Used in the last onboarding step and in Settings.
struct ModelSettingsForm: View {
    @Environment(AppModel.self) private var model
    /// Called after a successful save.
    var onSaved: () -> Void = {}

    @State private var settings = ModelSettings.default
    @State private var customModel = false
    @State private var apiKey = ""
    @State private var savedKeySuffix: String?
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case testing
        case ok(String)
        case failed(String)
    }

    private var provider: ProviderPreset? { ModelCatalog.provider(settings.providerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: Binding(get: { settings.providerID }, set: selectProvider)) {
                ForEach(ModelCatalog.providers) { Text($0.name).tag($0.id) }
            }

            if let provider, provider.protocols.count > 1 {
                Picker("Protocol", selection: Binding(get: { settings.protocolKind }, set: selectProtocol)) {
                    ForEach(provider.protocols) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            TextField("Endpoint", text: $settings.baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())

            if let provider, !provider.models.isEmpty, !customModel {
                Picker("Model", selection: Binding(get: { settings.model }, set: selectModel)) {
                    ForEach(provider.models) { preset in
                        Text(preset.note.isEmpty ? preset.name : "\(preset.name) — \(preset.note)").tag(preset.id)
                    }
                    Divider()
                    Text("Other model…").tag(Self.otherTag)
                }
            } else {
                TextField("Model ID", text: $settings.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                if let provider, !provider.models.isEmpty {
                    Button("Choose from the list") {
                        customModel = false
                        settings.model = provider.models.first?.id ?? ""
                    }
                    .buttonStyle(.link)
                }
            }

            SecureField(savedKeySuffix.map { "API key (saved: …\($0))" } ?? "API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            if let page = provider?.keyPage, !page.isEmpty, let url = URL(string: page) {
                Link("Get an API key", destination: url).font(.caption)
            }

            HStack {
                Button(status == .testing ? "Testing…" : "Save and test") { Task { await saveAndTest() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(status == .testing || settings.model.isEmpty || (apiKey.isEmpty && savedKeySuffix == nil))
                Spacer()
            }
            statusView

            Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
        .onAppear(perform: load)
    }

    private static let otherTag = "__other__"

    @ViewBuilder private var statusView: some View {
        switch status {
        case .idle, .testing: EmptyView()
        case .ok(let message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.callout)
        case .failed(let message): Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
        }
    }

    private var footnote: String {
        var parts = ["The key stays in this Mac's Keychain. While a task runs, screenshots and text from the virtual Mac are sent to the provider you choose."]
        if provider?.isClaude == false {
            parts.append("The model must accept images and call tools.")
        }
        if let notes = provider?.notes, !notes.isEmpty { parts.append(notes) }
        return parts.joined(separator: " ")
    }

    // MARK: Actions

    private func load() {
        settings = model.modelSettings
        customModel = !(provider?.models.contains { $0.id == settings.model } ?? false)
        refreshSavedKey()
    }

    private func refreshSavedKey() {
        savedKeySuffix = (try? model.secrets.read(settings.keychainAccount))?.suffix(4).description
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
                try model.secrets.write(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: settings.keychainAccount)
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
