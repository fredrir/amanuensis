import SwiftUI

@MainActor
struct ProviderSettingsView: View {
    @ObservedObject private var store = ProviderStore.shared
    @ObservedObject private var granite = GraniteInstaller.shared
    #if DEBUG
        @ObservedObject private var injectionObserver = InjectionObserver.shared
    #endif

    @State private var signedIn = false
    @State private var isSigningIn = false
    @State private var accountError: String?
    @State private var modelLoadID = UUID()
    @State private var models: [String] = []
    @State private var isLoadingModels = false
    @State private var modelError: String?
    @State private var isCustomModelActive: Bool = false
    @State private var testStatus: TestStatus?
    @State private var nameDraft = ""
    @State private var nameDraftProviderID: UUID?
    @FocusState private var isNameFocused: Bool
    @State private var providerPendingDeletion: AIProviderConfiguration?

    private enum TestStatus: Equatable {
        case testing
        case success(String)
        case failure(String)
    }

    private var provider: AIProviderConfiguration { store.activeProvider }

    var body: some View {
        Form {
            Section {
                LabeledContent("Provider:") {
                    Picker("", selection: providerSelection) {
                        Section("Subscriptions") {
                            Text("ChatGPT / Codex").tag("codex")
                            Text("Gemini Subscription").tag("geminiSubscription")
                        }
                        Section("Cloud Services") {
                            Text("Anthropic API").tag("anthropic")
                            Text("Google Gemini").tag("gemini")
                            Text("OpenAI").tag("openai")
                            Text("OpenRouter").tag("openrouter")
                            Text("Groq").tag("groq")
                        }
                        Section("Local AI") {
                            Text("Docling Granite").tag("granite")
                            Text("Ollama (Local)").tag("ollama")
                            Text("LM Studio (Local)").tag("lmstudio")
                        }
                        Section("Custom") {
                            ForEach(customProviders) { cp in
                                Text(cp.displayName).tag(cp.id.uuidString)
                            }
                            Text("+ Add Custom Provider…").tag("__add_custom__")
                        }
                    }
                    .labelsHidden()
                }

                if provider.isCustom {
                    LabeledContent("Name:") {
                        HStack(spacing: 8) {
                            TextField(
                                "Name",
                                text: $nameDraft,
                                prompt: Text(AIProviderPreset.custom.name)
                            )
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .focused($isNameFocused)
                            .onSubmit(commitNameDraft)

                            Button {
                                providerPendingDeletion = provider
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(store.providers.count <= 1)
                            .help("Delete this endpoint")
                        }
                    }
                }

                if provider.isSubscription {
                    LabeledContent("Account:") {
                        HStack {
                            Text(signedIn ? "Signed in" : "Not signed in")
                                .foregroundStyle(.secondary)
                            Spacer()
                            if isSigningIn { ProgressView().controlSize(.small) }
                            Button(signedIn ? "Sign Out" : "Sign In") {
                                Task { await changeAccount() }
                            }
                            .disabled(isSigningIn)
                        }
                    }
                    if isSigningIn {
                        Text("Complete sign-in in your browser.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Cancel Sign-In") { Task { await cancelSignIn() } }
                    }
                    if let accountError {
                        Text(accountError).font(.caption).foregroundStyle(.red)
                    }
                } else if provider.requiresAPIKey {
                    LabeledContent("API Key:") {
                        SecureField("API Key", text: stringBinding(for: \.apiKey), prompt: Text(apiKeyPlaceholder))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                    }
                } else if provider.kind == .granite {
                    GraniteSection(installer: granite)
                } else if provider.isLocal {
                    LabeledContent("API Key (optional):") {
                        SecureField("API Key", text: stringBinding(for: \.apiKey))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                    }
                }

                if isLocalOrCustom {
                    LabeledContent("API Endpoint:") {
                        TextField(
                            "Server URL",
                            text: stringBinding(for: \.baseURL),
                            prompt: Text(placeholderBaseURL)
                        )
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                    }

                }

                LabeledContent("Model:") {
                    HStack(spacing: 8) {
                        if provider.kind == .granite {
                            Text("Granite Docling 258M").foregroundStyle(.secondary)
                        } else if !models.isEmpty && !isCustomModelActive {
                            Picker("", selection: modelPickerBinding) {
                                if provider.resolvedModel.isEmpty {
                                    Text("Select a model").tag("")
                                }
                                ForEach(modelOptions, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                                Divider()
                                Text("Custom Model…").tag(Self.customModelTag)
                            }
                            .labelsHidden()
                        } else {
                            TextField("Model identifier", text: stringBinding(for: \.model))
                                .textFieldStyle(.roundedBorder)

                            if !models.isEmpty {
                                Button("Show List") {
                                    isCustomModelActive = false
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        }

                        Button {
                            Task { await loadModels() }
                        } label: {
                            if isLoadingModels {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isLoadingModels || !canLoadModels)
                        .help("Reload models from the provider")
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack(spacing: 4) {
                            if case .testing = testStatus {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "bolt.badge.checkmark")
                            }
                            Text("Test Connection")
                        }
                    }
                    .disabled(isLoadingModels || (testStatus != nil && isTestingConnection))

                    if let status = testStatus {
                        switch status {
                        case .testing:
                            Text("Connecting…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        case .success(let message):
                            Label(message, systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        case .failure(let message):
                            Label(message, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer()
                }
                .padding(.top, 4)

                if let modelError {
                    HStack {
                        Label(modelError, systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Dismiss") {
                            self.modelError = nil
                        }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                    }
                }
            } header: {
                Text("Configuration")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete \"\(providerPendingDeletion?.displayName ?? "")\"?",
            isPresented: isConfirmingDeletion,
            presenting: providerPendingDeletion
        ) { pending in
            Button("Delete", role: .destructive) {
                store.remove(id: pending.id)
            }
        } message: { _ in
            Text("Its endpoint URL, API key and model will be removed.")
        }
        .onChange(of: store.activeProviderID) { _, _ in
            commitNameDraft()
            resetModelList()
            testStatus = nil
            signedIn = false
            isSigningIn = false
            accountError = nil
        }
        .onChange(of: isNameFocused) { _, isFocused in
            if !isFocused { commitNameDraft() }
        }
        .onAppear(perform: loadNameDraft)
        .onDisappear(perform: commitNameDraft)
        .task(id: provider.id) {
            guard provider.isSubscription else { return }
            let id = provider.id
            do {
                let result = try await AIProviderClient().account("status", for: provider)
                guard id == provider.id else { return }
                signedIn = result["signedIn"] as? Bool ?? false
            } catch {
                guard id == provider.id else { return }
                accountError = error.localizedDescription
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BackendProcess.accountChanged)) { notification in
            guard notification.userInfo?["kind"] as? String == provider.kind.rawValue else { return }
            signedIn = notification.userInfo?["signedIn"] as? Bool ?? false
            isSigningIn = false
            accountError = notification.userInfo?["error"] as? String
        }
        .task(id: modelListSource) {
            resetModelList()
            testStatus = nil
            guard canLoadModels else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await loadModels()
        }
    }

    private var isTestingConnection: Bool {
        if case .testing = testStatus { return true }
        return false
    }

    private var isLocalOrCustom: Bool {
        (provider.isLocal && provider.kind != .granite) || provider.isCustom
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { providerPendingDeletion != nil },
            set: { if !$0 { providerPendingDeletion = nil } }
        )
    }

    private func loadNameDraft() {
        nameDraft = provider.name
        nameDraftProviderID = provider.id
    }

    private func commitNameDraft() {
        if let id = nameDraftProviderID {
            store.rename(id: id, to: nameDraft)
        }
        loadNameDraft()
    }

    private var placeholderBaseURL: String {
        let fallback = provider.kind.defaultBaseURL
        return fallback.isEmpty ? "https://example.com/v1" : fallback
    }

    private var apiKeyPlaceholder: String {
        if provider.kind == .gemini {
            return "AIzaSy..."
        }
        switch provider.presetID {
        case "anthropic": return "sk-ant-..."
        case "openai": return "sk-..."
        case "groq": return "gsk_..."
        default: return "sk-or-..."
        }
    }

    private var customProviders: [AIProviderConfiguration] {
        store.providers.filter(\.isCustom)
    }

    private var providerSelection: Binding<String> {
        Binding<String>(
            get: {
                provider.isCustom ? provider.id.uuidString : provider.presetID
            },
            set: { newSelection in
                if newSelection == "__add_custom__" {
                    let added = store.add(preset: .custom, activate: true)
                    store.setActiveProvider(added.id)
                    resetModelList()
                    return
                }

                if let preset = AIProviderPreset.all.first(where: { $0.id == newSelection }) {
                    if let existing = store.providers.first(where: { $0.presetID == preset.id }) {
                        store.setActiveProvider(existing.id)
                    } else {
                        let created = store.add(preset: preset, activate: true)
                        store.setActiveProvider(created.id)
                    }
                } else if let uuid = UUID(uuidString: newSelection) {
                    store.setActiveProvider(uuid)
                }
                resetModelList()
            }
        )
    }

    private static let customModelTag = "__custom__"

    private var modelOptions: [String] {
        let current = provider.resolvedModel
        guard !current.isEmpty, !models.contains(current) else { return models }
        return models + [current]
    }

    private var modelPickerBinding: Binding<String> {
        Binding<String>(
            get: { provider.resolvedModel },
            set: { newValue in
                if newValue == Self.customModelTag {
                    isCustomModelActive = true
                } else {
                    var updated = provider
                    updated.model = newValue
                    store.update(updated)
                }
            }
        )
    }

    private var canLoadModels: Bool {
        if provider.kind == .granite { return granite.state == .installed || granite.state == .unavailable }
        if provider.isSubscription { return signedIn }
        return !provider.requiresAPIKey || !provider.effectiveAPIKey.isEmpty
    }

    private var modelListSource: [String] {
        [provider.id.uuidString, provider.resolvedBaseURL, provider.effectiveAPIKey, String(signedIn), String(canLoadModels)]
    }

    private func resetModelList() {
        modelLoadID = UUID()
        isLoadingModels = false
        models = []
        modelError = nil
        isCustomModelActive = false
    }

    private func loadModels() async {
        let source = modelListSource
        let requestID = UUID()
        modelLoadID = requestID
        isLoadingModels = true
        modelError = nil
        defer { if modelLoadID == requestID { isLoadingModels = false } }

        do {
            let loaded = try await AIProviderClient().availableModels(for: provider)
            guard !Task.isCancelled, source == modelListSource, requestID == modelLoadID else { return }
            models = loaded
            isCustomModelActive = false
        } catch {
            guard !Task.isCancelled, source == modelListSource, requestID == modelLoadID else { return }
            models = []
            modelError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func testConnection() async {
        let source = modelListSource
        testStatus = .testing

        do {
            let loaded = try await AIProviderClient().availableModels(for: provider)
            guard source == modelListSource else { return }
            models = loaded
            testStatus = .success(
                "Connected! Loaded \(loaded.count) model\(loaded.count == 1 ? "" : "s").")
        } catch {
            guard source == modelListSource else { return }
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            testStatus = .failure(msg)
        }
    }

    private func changeAccount() async {
        let selected = provider
        isSigningIn = true
        accountError = nil
        do {
            let result = try await AIProviderClient().account(signedIn ? "logout" : "login", for: selected)
            guard selected.id == provider.id else { return }
            if let urlString = result["url"] as? String, let url = URL(string: urlString), url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
            if let value = result["signedIn"] as? Bool { signedIn = value }
            isSigningIn = result["pending"] as? Bool ?? false
        } catch {
            guard selected.id == provider.id else { return }
            isSigningIn = false
            accountError = error.localizedDescription
        }
    }

    private func cancelSignIn() async {
        let selected = provider
        do { _ = try await AIProviderClient().account("logout", for: selected) }
        catch { accountError = error.localizedDescription }
        guard selected.id == provider.id else { return }
        isSigningIn = false
        signedIn = false
    }

    private func binding<Value>(for field: WritableKeyPath<AIProviderConfiguration, Value>)
        -> Binding<Value>
    {
        Binding(
            get: { provider[keyPath: field] },
            set: { newValue in
                var updated = provider
                updated[keyPath: field] = newValue
                store.update(updated)
            }
        )
    }

    private func stringBinding(for field: WritableKeyPath<AIProviderConfiguration, String>)
        -> Binding<String>
    {
        binding(for: field)
            .trimmed()
    }
}

private struct GraniteSection: View {
    @ObservedObject var installer: GraniteInstaller
    @State private var isConfirmingRemoval = false

    var body: some View {
        Text("Runs entirely on this Mac. No account or API key required.")
            .font(.subheadline).foregroundStyle(.secondary)
        LabeledContent("Local Model:") {
            HStack(spacing: 8) {
                switch installer.state {
                case .unavailable:
                    #if DEBUG
                        Text("Provided by just backend-setup").foregroundStyle(.secondary)
                    #else
                        Text("Not downloadable in this build").foregroundStyle(.secondary)
                    #endif
                case .notInstalled:
                    Text("Not installed").foregroundStyle(.secondary)
                    Spacer()
                    Button("Download (\(installer.downloadSize))") { installer.install() }
                case .downloading(let fraction):
                    ProgressView(value: fraction).frame(maxWidth: 160)
                    Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                        .monospacedDigit().foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { installer.cancel() }
                case .installing:
                    ProgressView().controlSize(.small)
                    Text("Installing…").foregroundStyle(.secondary)
                    Spacer()
                case .installed:
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Remove…") { isConfirmingRemoval = true }
                case .failed:
                    Text("Download failed").foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { installer.install() }
                }
            }
        }
        .confirmationDialog("Remove Docling Granite?", isPresented: $isConfirmingRemoval) {
            Button("Remove", role: .destructive) { installer.remove() }
        } message: {
            Text("Local extraction will need another \(installer.downloadSize) download.")
        }
        if case .failed(let message) = installer.state {
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}

extension Binding where Value == String {
    fileprivate func trimmed() -> Binding<String> {
        Binding<String>(
            get: { wrappedValue },
            set: { newValue in
                wrappedValue = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        )
    }
}
