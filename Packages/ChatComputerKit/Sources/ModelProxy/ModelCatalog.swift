import Foundation

/// How the app talks to a model endpoint.
public enum ModelProtocol: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Anthropic Messages API (`{base}/v1/messages`).
    case anthropic
    /// OpenAI Chat Completions (`{base}/chat/completions`).
    case openAI

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .anthropic: "Anthropic-compatible"
        case .openAI: "OpenAI-compatible"
        }
    }
}

/// One model a provider offers. The agent works from screenshots, so only models that take images
/// and call tools can run tasks; the others are listed so the user knows why they are missing.
public struct ModelPreset: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var note: String
    /// Takes image input. Without it the model cannot see the screen and cannot run tasks.
    public var vision: Bool

    public init(_ id: String, _ name: String, note: String = "", vision: Bool = true) {
        self.id = id
        self.name = name
        self.note = note
        self.vision = vision
    }
}

/// A model vendor: its endpoints per protocol and its current models.
public struct ProviderPreset: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Base URLs: Anthropic protocol → `{base}/v1/messages`; OpenAI protocol → `{base}/chat/completions`.
    public var endpoints: [ModelProtocol: String]
    public var models: [ModelPreset]
    /// Where to create an API key.
    public var keyPage: String
    public var notes: String

    public var protocols: [ModelProtocol] { ModelProtocol.allCases.filter { endpoints[$0] != nil } }
    /// Anthropic's own API, the only one with the server-side computer toolset.
    public var isClaude: Bool { id == "anthropic" }
}

/// Built-in vendors. Model IDs verified against vendor documentation on the date in `verifiedOn`;
/// any other model ID can be typed in, and "Custom" covers any compatible endpoint.
public enum ModelCatalog {
    public static let verifiedOn = "2026-10-01"

    public static let providers: [ProviderPreset] = [
        ProviderPreset(
            id: "anthropic", name: "Anthropic (Claude)",
            endpoints: [.anthropic: "https://api.anthropic.com"],
            models: [
                ModelPreset("claude-opus-5-5", "Claude Opus 5.5", note: "Recommended"),
                ModelPreset("claude-sonnet-5-5", "Claude Sonnet 5.5", note: "Faster, lower cost"),
                ModelPreset("claude-fable-5-1", "Claude Fable 5.1", note: "Most capable, highest cost"),
            ],
            keyPage: "https://console.anthropic.com/settings/keys",
            notes: "Uses Claude's built-in computer use toolset."),
        ProviderPreset(
            id: "openai", name: "OpenAI",
            endpoints: [.openAI: "https://api.openai.com/v1"],
            models: [
                ModelPreset("gpt-6-astra", "GPT-6 Astra", note: "Flagship"),
                ModelPreset("gpt-5.6-terra", "GPT-5.6 Terra"),
                ModelPreset("gpt-5.4-mini", "GPT-5.4 mini", note: "Lower cost"),
            ],
            keyPage: "https://platform.openai.com/api-keys",
            notes: "GPT-6.1 Sol cannot call tools through Chat Completions, so it is not listed."),
        ProviderPreset(
            id: "google", name: "Google Gemini",
            endpoints: [.openAI: "https://generativelanguage.googleapis.com/v1beta/openai"],
            models: [
                ModelPreset("gemini-3.8-flash", "Gemini 3.8 Flash", note: "Newest"),
                ModelPreset("gemini-3.1-pro-preview", "Gemini 3.1 Pro (preview)"),
                ModelPreset("gemini-3.7-flash", "Gemini 3.7 Flash"),
                ModelPreset("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite", note: "Lowest cost"),
            ],
            keyPage: "https://aistudio.google.com/apikey",
            notes: "Google's OpenAI-compatible endpoint is in beta."),
        ProviderPreset(
            id: "deepseek", name: "DeepSeek",
            endpoints: [.openAI: "https://api.deepseek.com/v1", .anthropic: "https://api.deepseek.com/anthropic"],
            models: [
                ModelPreset("deepseek-flash", "DeepSeek V4.1 Flash", note: "Recommended"),
                ModelPreset("deepseek-v4-flash", "DeepSeek V4 Flash", note: "Older name, served by V4.1 Flash"),
                ModelPreset("deepseek-v4-pro", "DeepSeek V4 Pro", note: "No image input", vision: false),
            ],
            keyPage: "https://platform.deepseek.com/api_keys",
            notes: "DeepSeek V4.1 Flash is DeepSeek's model with image input."),
        ProviderPreset(
            id: "xai", name: "xAI (Grok)",
            endpoints: [.openAI: "https://api.x.ai/v1"],
            models: [
                ModelPreset("grok-4.7", "Grok 4.7", note: "Flagship"),
                ModelPreset("grok-4.6", "Grok 4.6"),
                ModelPreset("grok-4.3", "Grok 4.3", note: "Fast"),
            ],
            keyPage: "https://console.x.ai",
            notes: ""),
        ProviderPreset(
            id: "mistral", name: "Mistral",
            endpoints: [.openAI: "https://api.mistral.ai/v1"],
            models: [
                ModelPreset("mistral-medium-latest", "Mistral Medium 3.5"),
                ModelPreset("mistral-large-latest", "Mistral Large"),
                ModelPreset("mistral-small-latest", "Mistral Small", note: "Lower cost"),
            ],
            keyPage: "https://console.mistral.ai/api-keys",
            notes: "Mistral accepts at most 8 images per request; Chat Computer sends the 3 most recent screenshots."),
        ProviderPreset(
            id: "qwen", name: "Alibaba Qwen",
            endpoints: [.openAI: "https://dashscope-intl.aliyuncs.com/compatible-mode/v1",
                        .anthropic: "https://dashscope-intl.aliyuncs.com/apps/anthropic"],
            models: [
                ModelPreset("qwen3.8-max", "Qwen3.8 Max", note: "Flagship"),
                ModelPreset("qwen3.7-plus", "Qwen3.7 Plus"),
                ModelPreset("qwen3.8-flash", "Qwen3.8 Flash", note: "Lower cost"),
            ],
            keyPage: "https://modelstudio.console.alibabacloud.com",
            notes: "International endpoint. In mainland China use dashscope.aliyuncs.com instead of dashscope-intl.aliyuncs.com."),
        ProviderPreset(
            id: "moonshot", name: "Moonshot Kimi",
            endpoints: [.openAI: "https://api.moonshot.ai/v1", .anthropic: "https://api.moonshot.ai/anthropic"],
            models: [
                ModelPreset("kimi-k3", "Kimi K3", note: "Flagship"),
                ModelPreset("kimi-k2.6", "Kimi K2.6"),
                ModelPreset("kimi-k2.7-code", "Kimi K2.7 Code", note: "Image input not confirmed"),
            ],
            keyPage: "https://platform.kimi.ai/console/api-keys",
            notes: "In mainland China use api.moonshot.cn instead of api.moonshot.ai."),
        ProviderPreset(
            id: "zhipu", name: "Zhipu GLM",
            endpoints: [.openAI: "https://api.z.ai/api/paas/v4", .anthropic: "https://api.z.ai/api/anthropic"],
            models: [
                ModelPreset("glm-5.3-flash", "GLM-5.3 Flash"),
                ModelPreset("glm-5.3-flashx", "GLM-5.3 FlashX"),
                ModelPreset("glm-4.6v", "GLM-4.6V"),
                ModelPreset("glm-5.3", "GLM-5.3", note: "No image input", vision: false),
            ],
            keyPage: "https://z.ai/manage-apikey/apikey-list",
            notes: "In mainland China use open.bigmodel.cn instead of api.z.ai."),
        ProviderPreset(
            id: "doubao", name: "ByteDance Doubao",
            endpoints: [.openAI: "https://ark.cn-beijing.volces.com/api/v3"],
            models: [
                ModelPreset("doubao-seed-2-1-pro-260915", "Doubao Seed 2.1 Pro", note: "Flagship"),
                ModelPreset("doubao-seed-2-1-lite-260915", "Doubao Seed 2.1 Lite"),
                ModelPreset("doubao-seed-2-1-turbo-260628", "Doubao Seed 2.1 Turbo"),
            ],
            keyPage: "https://console.volcengine.com/ark",
            notes: "Volcengine Ark (China). The international BytePlus ModelArk endpoint uses different model IDs."),
        ProviderPreset(
            id: "custom", name: "Custom endpoint",
            endpoints: [.openAI: "http://localhost:11434/v1", .anthropic: "https://"],
            models: [],
            keyPage: "",
            notes: "Any OpenAI- or Anthropic-compatible endpoint, such as a local server. The model must accept images and call tools."),
    ]

    public static func provider(_ id: String) -> ProviderPreset? {
        providers.first { $0.id == id }
    }
}

/// The user's model choice. Saved in user defaults; the API key is stored under `secretAccount` (`HostSecretStore`).
public struct ModelSettings: Codable, Sendable, Equatable {
    public var providerID: String
    public var protocolKind: ModelProtocol
    public var baseURL: String
    public var model: String

    public init(providerID: String, protocolKind: ModelProtocol, baseURL: String, model: String) {
        self.providerID = providerID
        self.protocolKind = protocolKind
        self.baseURL = baseURL
        self.model = model
    }

    public static let `default` = ModelSettings(providerID: "anthropic", protocolKind: .anthropic,
                                                baseURL: "https://api.anthropic.com", model: "claude-opus-5-5")

    /// One key per provider. Anthropic keeps the account name the app always used.
    public static func secretAccount(for providerID: String) -> String { "model.\(providerID).apiKey" }
    public var secretAccount: String { Self.secretAccount(for: providerID) }

    /// A settings value for a provider's default protocol, endpoint and first model.
    public static func preset(_ provider: ProviderPreset) -> ModelSettings {
        let kind = provider.isClaude ? ModelProtocol.anthropic : (provider.protocols.contains(.openAI) ? .openAI : .anthropic)
        return ModelSettings(providerID: provider.id, protocolKind: kind, baseURL: provider.endpoints[kind] ?? "",
                             model: provider.models.first?.id ?? "")
    }

    /// Builds the client for these settings. `displayWidth/Height` is the guest screen in points.
    public func makeClient(displayWidth: Int = 1280, displayHeight: Int = 800,
                           apiKey: @escaping @Sendable () throws -> String?) throws -> any ModelClient {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = URL(string: trimmed), base.scheme == "https" || base.scheme == "http", base.host() != nil else {
            throw ModelError.badRequest("The endpoint URL is not valid: \(baseURL)")
        }
        guard !model.isEmpty else { throw ModelError.badRequest("Choose a model.") }
        switch protocolKind {
        case .anthropic:
            let dialect: AnthropicClient.Configuration.Dialect = providerID == "anthropic"
                ? .claude : .compatible(displayWidth: displayWidth, displayHeight: displayHeight)
            return AnthropicClient(configuration: .init(model: model, endpoint: base.appendingPathComponent("v1/messages"),
                                                        dialect: dialect), apiKey: apiKey)
        case .openAI:
            return OpenAICompatibleClient(configuration: .init(
                // OpenAI and xAI want max_completion_tokens; max_tokens is deprecated or rejected there.
                model: model, baseURL: base, usesMaxCompletionTokens: ["api.openai.com", "api.x.ai"].contains(base.host() ?? ""),
                displayWidth: displayWidth, displayHeight: displayHeight), apiKey: apiKey)
        }
    }
}

/// A one-message request that checks the key, endpoint and model, without tools.
public enum ConnectionTest {
    public static func run(_ client: any ModelClient) async -> Result<String, ModelError> {
        do {
            let response = try await client.respond(
                system: "You are a connection test. Reply with the single word OK.",
                tools: [],
                messages: [["role": "user", "content": "Reply with OK."]])
            let text = response.blocks.compactMap { block -> String? in
                if case .text(let value) = block { return value }
                return nil
            }.joined()
            return .success("Connected to \(response.servedModel ?? client.modelID): \(text.prefix(40))")
        } catch let error as ModelError {
            return .failure(error)
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}
