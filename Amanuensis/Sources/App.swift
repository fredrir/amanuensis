import AppKit
import Carbon
import Combine
import CoreGraphics
import Foundation
import ServiceManagement
import os.log

struct HistoryEntry: Codable {
    let text: String
    let promptId: UUID?  // nil for plain text
    let promptName: String  // "Text (OCR)" or prompt name
    let timestamp: Date

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }
}

@MainActor
class HistoryManager {
    static let shared = HistoryManager()
    private let maxEntries = 10
    private var entries: [HistoryEntry] = []

    func addEntry(_ text: String, promptId: UUID?, promptName: String) {
        let entry = HistoryEntry(
            text: text, promptId: promptId, promptName: promptName, timestamp: Date())
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast()
        }
    }

    func clearHistory() {
        entries.removeAll()
    }

    var recentEntries: [HistoryEntry] {
        return entries
    }
}

@MainActor
final class App: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    private var pasteboardObserver: Timer?
    private var pasteboardChangeCount = 0
    private var settingsWindowController: SettingsWindowController?
    private let settingsManager = SettingsManager.shared
    private let historyManager = HistoryManager.shared
    private lazy var permissionManager = ScreenCapturePermissionManager.shared
    private let screenCaptureService = ScreenCaptureService()

    private var isExtracting = false
    private var isRequestingPermission = false
    private var isFullySetup = false
    private var isShortcutMonitoringSetup = false
    private var originalStatusImage: NSImage?
    private var currentFeedbackTask: Task<Void, Never>?

    private lazy var extractTextItem: NSMenuItem = {
        let item = NSMenuItem(title: "Extract Text")
        item.addAction { [weak self] in
            self?.initiateCaptureForText()
        }
        return item
    }()

    private var promptMenuItems: [NSMenuItem] = []

    private lazy var settingsItem: NSMenuItem = {
        let item = NSMenuItem(title: "Settings", action: nil, keyEquivalent: ",")
        item.addAction { [weak self] in
            self?.showSettings()
        }
        return item
    }()

    private lazy var quitItem: NSMenuItem = {
        let item = NSMenuItem(title: "Quit", action: nil, keyEquivalent: "q")
        item.keyEquivalentModifierMask = .command
        item.addAction {
            NSApp.terminate(nil)
        }
        return item
    }()

    private lazy var historyMenu: NSMenu = {
        let menu = NSMenu()
        return menu
    }()

    private lazy var historyItem: NSMenuItem = {
        let item = NSMenuItem(title: "Recent Captures")
        item.submenu = historyMenu
        return item
    }()

    private lazy var clearHistoryItem: NSMenuItem = {
        let item = NSMenuItem(title: "Clear History")
        item.addAction { [weak self] in
            self?.historyManager.clearHistory()
        }
        return item
    }()

    private var statusItemMenu: NSMenu?

    private lazy var statusItem: NSStatusItem = {
        Logger.log(.info, "Creating status item...")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = .terminationOnRemoval
        item.button?.image = .with(symbolName: "text.viewfinder", pointSize: 15)
        Logger.log(
            .info,
            "Status item button: \(String(describing: item.button)), image: \(String(describing: item.button?.image))"
        )

        let menu = NSMenu()
        menu.delegate = self
        statusItemMenu = menu

        rebuildMenu()

        item.menu = menu
        return item
    }()

    private let providerStore = ProviderStore.shared
    private let providerClient = AIProviderClient()
    private static let soundPath =
        "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aiff"

    private func rebuildMenu() {
        guard let menu = statusItemMenu else { return }
        menu.removeAllItems()

        // Extract Text
        menu.addItem(extractTextItem)
        menu.addItem(.separator())

        // Prompts section
        promptMenuItems.removeAll()
        for prompt in Prompt.builtInPrompts {
            let item = NSMenuItem(title: prompt.name)
            item.addAction { [weak self] in
                self?.initiateCapture(with: prompt)
            }
            promptMenuItems.append(item)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(historyItem)
        if let providerItem = providerMenuItem() {
            menu.addItem(.separator())
            menu.addItem(providerItem)
        }
        menu.addItem(.separator())
        menu.addItem(settingsItem)
        menu.addItem(quitItem)

        updateMenuItemKeyEquivalents()
        applyCaptureMenuState(permissionGranted: permissionManager.hasPermission)
    }

    /// Submenu for switching the active provider, shown once more than one exists.
    private func providerMenuItem() -> NSMenuItem? {
        guard providerStore.providers.count > 1 else { return nil }

        let item = NSMenuItem(title: "Provider")
        let submenu = NSMenu()
        for provider in providerStore.providers {
            let providerItem = NSMenuItem(title: provider.displayName)
            providerItem.state = provider.id == providerStore.activeProviderID ? .on : .off
            providerItem.addAction { [weak self] in
                self?.providerStore.setActiveProvider(provider.id)
            }
            submenu.addItem(providerItem)
        }
        item.submenu = submenu
        return item
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // Application menu (macOS replaces the title with the app name)
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenuItem.submenu = appMenu

        let aboutItem = NSMenuItem(
            title: "About ScreenScribe",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

        let settingsMenuItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ",")
        settingsMenuItem.target = self
        appMenu.addItem(settingsMenuItem)
        appMenu.addItem(.separator())

        appMenu.addItem(
            NSMenuItem(
                title: "Hide ScreenScribe",
                action: #selector(NSApplication.hide(_:)),
                keyEquivalent: "h"))
        appMenu.addItem(
            NSMenuItem(
                title: "Quit ScreenScribe",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"))

        // File menu provides the standard Close (⌘W) item for the settings window.
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = NSMenu(title: "File")
        mainMenu.addItem(fileMenuItem)
        let fileMenu = fileMenuItem.submenu!
        fileMenu.addItem(
            NSMenuItem(
                title: "Close",
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w"))

        // Edit menu with standard items
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = NSMenu(title: "Edit")
        mainMenu.addItem(editMenuItem)

        let editMenu = editMenuItem.submenu!
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(
            NSMenuItem(
                title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        NSApp.mainMenu = mainMenu
    }

    func statusItemInfo() -> (rect: CGRect, screen: NSScreen?)? {
        guard let button = statusItem.button, let window = button.window else {
            Logger.log(.error, "Missing button or window to provide positioning info")
            return nil
        }

        return (window.convertToScreen(button.frame), window.screen ?? .main)
    }

    @objc func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Logger.log(.info, "applicationDidFinishLaunching started")
        #if DEBUG
        InjectionSupport.bootstrap()
        #endif
        setupMainMenu()
        do { try BackendProcess.shared.start() }
        catch { Logger.log(.error, "Backend startup failed: \(error.localizedDescription)") }

        // After a dev-mode hot reload, bring the settings window back where it was.
        if CommandLine.arguments.contains("--restore-settings"),
            UserDefaults.standard.bool(forKey: SettingsPersistence.windowWasOpenKey)
        {
            showSettings()
        }

        // Always show the status item
        Logger.log(.info, "About to access statusItem.isVisible")
        statusItem.isVisible = true
        Logger.log(
            .info, "Status item isVisible set to true, actual value: \(self.statusItem.isVisible)")
        Logger.log(.info, "Status item button exists: \(self.statusItem.button != nil)")

        Logger.log(.info, "Proceeding with normal startup")
        proceedWithNormalStartup()
    }

    /// Normal startup procedure
    private func proceedWithNormalStartup() {
        setupShortcutMonitoringIfNeeded()

        // Check permission status
        if permissionManager.checkPermission() {
            // Permission already granted, proceed normally
            onPermissionGranted()
        } else {
            // Keep the app in a non-blocking state and monitor silently.
            // Permission requests are only triggered by user capture actions.
            updateMenuForLimitedState()
            Task {
                await permissionManager.startMonitoringWithoutPrompt()
            }
        }

        // Subscribe to permission changes
        permissionManager.$hasPermission
            .dropFirst()  // Skip the initial value
            .receive(on: DispatchQueue.main)
            .sink { [weak self] granted in
                if granted {
                    self?.onPermissionGranted()
                } else {
                    self?.updateMenuForLimitedState()
                }
            }
            .store(in: &cancellables)

        // Observe provider changes so the menu reflects the active provider
        providerStore.$providers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        providerStore.$activeProviderID
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Normal quit: a later dev launch shouldn't restore the settings window.
        UserDefaults.standard.set(false, forKey: SettingsPersistence.windowWasOpenKey)
        BackendProcess.shared.stop()
        ShortcutMonitor.shared.stopMonitoring()
        permissionManager.stopPolling()
    }

    // MARK: - Permission Handling

    /// Show a clean, minimal alert explaining the permission requirement.
    /// Returns true when user chooses to continue with the system prompt.
    private func showPermissionRequiredAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Permission"
        alert.informativeText =
            "ScreenScribe needs Screen Recording permission to capture screen regions.\n\nContinue to request permission now, or open System Settings to enable it manually."
        alert.alertStyle = .informational

        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertSecondButtonReturn {
            permissionManager.openSystemSettings()
            Task {
                await permissionManager.startMonitoringWithoutPrompt()
            }
            return false
        }

        return response == .alertFirstButtonReturn
    }

    private func applyCaptureMenuState(permissionGranted: Bool) {
        extractTextItem.isEnabled = true
        extractTextItem.title =
            permissionGranted
            ? "Extract Text"
            : "Extract Text (Permission Required)"

        for (index, prompt) in Prompt.builtInPrompts.enumerated() {
            guard index < promptMenuItems.count else { continue }
            promptMenuItems[index].isEnabled = true
            promptMenuItems[index].title =
                permissionGranted
                ? prompt.name
                : prompt.name + " (Permission Required)"
        }
    }

    /// Update menu items to reflect limited state (permission required)
    private func updateMenuForLimitedState() {
        applyCaptureMenuState(permissionGranted: false)
    }

    /// Called when permission is granted (either immediately or after polling)
    private func onPermissionGranted() {
        applyCaptureMenuState(permissionGranted: true)
        // Setup full functionality if not already done
        setupFullFunctionality()
    }

    private func setupShortcutMonitoringIfNeeded() {
        guard !isShortcutMonitoringSetup else { return }
        isShortcutMonitoringSetup = true

        ShortcutMonitor.shared.startMonitoring { [weak self] action in
            switch action {
            case .visionOCR:
                self?.initiateCaptureForText()
            case .latex:
                self?.initiateCapture(with: Prompt.latexPrompt)
            case .markdown:
                self?.initiateCapture(with: Prompt.markdownPrompt)
            }
        }
    }

    /// Setup permission-dependent observers (called after permission granted)
    private func setupFullFunctionality() {
        guard !isFullySetup else { return }
        isFullySetup = true

        updateMenuItemKeyEquivalents()

        settingsManager.$textShortcut
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuItemKeyEquivalents()
            }
            .store(in: &cancellables)

        settingsManager.$latexShortcut
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuItemKeyEquivalents()
            }
            .store(in: &cancellables)

        settingsManager.$markdownShortcut
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateMenuItemKeyEquivalents()
            }
            .store(in: &cancellables)
    }

    @MainActor
    private func updateMenuItemKeyEquivalents() {
        // Text shortcut
        if let shortcut = settingsManager.textShortcut {
            extractTextItem.keyEquivalent = shortcut.keyEquivalentCharacter
            extractTextItem.keyEquivalentModifierMask = shortcut.modifiers
        } else {
            extractTextItem.keyEquivalent = ""
            extractTextItem.keyEquivalentModifierMask = []
        }

        // Prompt shortcuts (LaTeX and Markdown)
        for (index, prompt) in Prompt.builtInPrompts.enumerated() {
            guard index < promptMenuItems.count else { continue }
            let item = promptMenuItems[index]

            let shortcut: ShortcutMonitor.KeyboardShortcut?
            if prompt.id == Prompt.latexPromptId {
                shortcut = settingsManager.latexShortcut
            } else if prompt.id == Prompt.markdownPromptId {
                shortcut = settingsManager.markdownShortcut
            } else {
                shortcut = nil
            }

            item.state = .off
            if let shortcut {
                item.keyEquivalent = shortcut.keyEquivalentCharacter
                item.keyEquivalentModifierMask = shortcut.modifiers
            } else {
                item.keyEquivalent = ""
                item.keyEquivalentModifierMask = []
            }
        }
    }

    @objc func menuWillOpen(_ menu: NSMenu) {
        updateMenuItemKeyEquivalents()
        updateHistoryMenu()
        startDetection()
    }

    func menuDidClose(_ menu: NSMenu) {
    }

    // MARK: - Capture Methods

    private func ensurePermissionThenCapture(
        _ action: @escaping @MainActor () async -> Void
    ) {
        Task { @MainActor in
            if permissionManager.checkPermission() {
                onPermissionGranted()
                await action()
                return
            }

            guard !isRequestingPermission else {
                Logger.log(
                    .info,
                    "Permission request already in progress; ignoring duplicate capture request")
                return
            }

            isRequestingPermission = true
            defer { isRequestingPermission = false }

            guard showPermissionRequiredAlert() else {
                return
            }

            let granted = await permissionManager.requestPermissionInteractively()

            if granted || permissionManager.checkPermission() {
                onPermissionGranted()
                await action()
            } else {
                updateMenuForLimitedState()
                let alert = NSAlert()
                alert.messageText = "Screen Recording Permission"
                alert.informativeText =
                    "macOS has not granted Screen Recording access to ScreenScribe. Open System Settings to review its access. If macOS asks you to quit and reopen the app, do so before capturing again."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    permissionManager.openSystemSettings()
                }
            }
        }
    }

    /// Initiate plain text capture
    func initiateCaptureForText() {
        ensurePermissionThenCapture { [weak self] in
            guard let self else { return }
            if let image = await self.screenCaptureService.captureSelectionImage() {
                self.performExtraction(image: image, prompt: nil)
            }
        }
    }

    /// Initiate capture with a specific prompt
    func initiateCapture(with prompt: Prompt) {
        ensurePermissionThenCapture { [weak self] in
            guard let self else { return }
            if let image = await self.screenCaptureService.captureSelectionImage() {
                self.performExtraction(image: image, prompt: prompt)
            }
        }
    }

    private func startDetection() {
        guard statusItem.menu != nil else {
            return Logger.assertFail("Missing menu to proceed")
        }

        pasteboardChangeCount = NSPasteboard.general.changeCount
    }

    // MARK: - Extraction

    private func performExtraction(image: NSImage, prompt: Prompt?) {
        guard !isExtracting else {
            NSAlert.showModalAlert(message: "An extraction is already in progress. Please wait.")
            return
        }

        let provider = providerStore.activeProvider
        guard let tiffData = image.tiffRepresentation,
            let bitmapImage = NSBitmapImageRep(data: tiffData),
            let imageData = bitmapImage.representation(using: .png, properties: [:])
        else {
            Logger.log(.error, "Failed to convert image to PNG data for extraction")
            NSAlert.showModalAlert(message: "Failed to process image data.")
            return
        }

        let base64Image = imageData.base64EncodedString()

        isExtracting = true

        Task {
            defer { isExtracting = false }

            do {
                let extractedContent = try await providerClient.extractContent(
                    from: base64Image,
                    format: prompt?.format ?? "text",
                    provider: provider
                )
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(extractedContent, forType: .string) {
                    showSuccessFeedback()
                    historyManager.addEntry(extractedContent, promptId: prompt?.id, promptName: prompt?.name ?? "Text")
                }
            } catch {
                NSAlert.showModalAlert(
                    message: "Failed to extract content: \(error.localizedDescription)")
                Logger.log(.error, "Extraction failed: \(error)")
            }
        }
    }

    func showSuccessFeedback() {
        // Cancel any existing feedback task
        currentFeedbackTask?.cancel()

        // Play screenshot sound
        if let soundURL = Bundle.main.url(forResource: "Screen Capture", withExtension: "aif"),
            let screenshotSound = NSSound(contentsOf: soundURL, byReference: true)
        {
            screenshotSound.play()
        } else {
            Logger.log(.error, "Could not load screenshot sound file from app bundle")
        }

        // Update status item icon with proper state management
        if let button = self.statusItem.button {
            if originalStatusImage == nil {
                originalStatusImage = button.image
            }
            button.image = .with(symbolName: "checkmark.circle.fill", pointSize: 15)

            // Create new feedback restoration task
            currentFeedbackTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)  // 1.5 seconds
                if !Task.isCancelled, let self = self {
                    button.image = self.originalStatusImage
                }
            }
        }
    }

    private func updateHistoryMenu() {
        historyMenu.removeAllItems()

        let entries = historyManager.recentEntries
        if entries.isEmpty {
            let emptyItem = NSMenuItem(title: "No Recent Captures")
            emptyItem.isEnabled = false
            historyMenu.addItem(emptyItem)
        } else {
            for entry in entries {
                let menuItem = NSMenuItem(
                    title: "\(entry.formattedDate) - \(entry.promptName)",
                    action: nil,
                    keyEquivalent: ""
                )

                let submenu = NSMenu()
                let previewText = entry.text.prefix(50)
                let previewItem = NSMenuItem(
                    title: previewText + (entry.text.count > 50 ? "..." : ""), action: nil,
                    keyEquivalent: "")
                previewItem.isEnabled = false
                submenu.addItem(previewItem)
                submenu.addItem(.separator())

                let copyItem = NSMenuItem(title: "Copy")
                copyItem.addAction { [weak self] in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    self?.showSuccessFeedback()
                }
                submenu.addItem(copyItem)

                menuItem.submenu = submenu
                historyMenu.addItem(menuItem)
            }

            historyMenu.addItem(.separator())
            historyMenu.addItem(clearHistoryItem)
        }
    }
}

extension App: NSMenuDelegate {
    // No duplicate methods here - they're already defined in the main class
}

extension NSAlert {
    static func showModalAlert(message: String, informativeText: String = "") {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
