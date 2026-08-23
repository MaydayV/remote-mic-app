import AppKit
import Combine
import CoreBluetooth
import Darwin
import Sparkle
import SwiftUI

struct UpdateFeedSelection {
    let stableFeedURLString: String?

    init(stableFeedURLString: String?) {
        self.stableFeedURLString = stableFeedURLString
    }

    func feedURLString() -> String? {
        stableFeedURLString
    }
}

@main
enum RemoteMicApp {
    @MainActor
    static func main() {
        if let screenshotDirectory = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_SETTINGS_SCREENSHOT_DIR"
        ] {
            do {
                try OnboardingScreenshotRenderer.renderSiriRemoteSettings(
                    to: URL(fileURLWithPath: screenshotDirectory, isDirectory: true),
                    appearanceName: ProcessInfo.processInfo.environment[
                        "REMOTE_MIC_SETTINGS_SCREENSHOT_APPEARANCE"
                    ]
                )
            } catch {
                fputs("Settings screenshot rendering failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        if let screenshotDirectory = ProcessInfo.processInfo.environment[
            "REMOTE_MIC_ONBOARDING_SCREENSHOT_DIR"
        ] {
            do {
                try OnboardingScreenshotRenderer.renderAll(
                    to: URL(fileURLWithPath: screenshotDirectory, isDirectory: true),
                    appearanceName: ProcessInfo.processInfo.environment[
                        "REMOTE_MIC_ONBOARDING_SCREENSHOT_APPEARANCE"
                    ]
                )
            } catch {
                fputs("Onboarding screenshot rendering failed: \(error)\n", stderr)
                exit(EXIT_FAILURE)
            }
            return
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier
            ?? ApplicationInstanceGuard.fallbackBundleIdentifier
        if let existingApplication = ApplicationInstanceGuard.existingApplication(
            bundleIdentifier: bundleIdentifier
        ) {
            existingApplication.activate(options: [.activateAllWindows])
            return
        }

        var instanceLock: ApplicationInstanceLock?
        if let lockURL = ApplicationInstanceGuard.defaultLockURL() {
            switch ApplicationInstanceLock.acquire(at: lockURL) {
            case let .acquired(lock):
                instanceLock = lock
            case .alreadyLocked:
                ApplicationInstanceGuard.existingApplication(
                    bundleIdentifier: bundleIdentifier
                )?.activate(options: [.activateAllWindows])
                return
            case let .failed(reason):
                fputs("Single-instance lock unavailable: \(reason)\n", stderr)
            }
        } else {
            fputs("Single-instance lock unavailable: application_support_missing\n", stderr)
        }

        let application = NSApplication.shared
        let delegate = RemoteMicAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(delegate.activationPolicy)
        withExtendedLifetime(instanceLock) {
            withExtendedLifetime(delegate) {
                application.run()
            }
        }
    }
}

@MainActor
private final class RemoteMicAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate,
    SPUUpdaterDelegate
{
    private enum UpdateCheckPurpose {
        case information
        case userInitiated
    }

    private let model = BridgeAppModel()
    private let updateInformation = UpdateInformationStore()
    private lazy var localization = LocalizationStore(settings: model.settings)
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    private var settingsWindowController: NSWindowController?
    private var subscriptions = Set<AnyCancellable>()
    private var terminationSignalSources: [DispatchSourceSignal] = []
    private var applicationShortcutMonitor: Any?
    private var workspaceAudioLifecycleObservers: [NSObjectProtocol] = []
    private var updateFeedSelection = UpdateFeedSelection(
        stableFeedURLString: Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String
    )
    private var updaterStarted = false
    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: nil
    )

    private let connectionItem = NSMenuItem()
    private let audioItem = NSMenuItem()
    private let hidItem = NSMenuItem()

    var activationPolicy: NSApplication.ActivationPolicy {
        model.settings.showDockIcon ? .regular : .accessory
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let currentBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        let completedUpdate = model.settings.recordLaunchAndDetectCompletedUpdate(
            currentBuild: currentBuild,
            sparkleHadLaunchedBefore: UserDefaults.standard.bool(forKey: "SUHasLaunchedBefore")
        )
        configureUpdater()
        installTerminationSignalHandlers()
        configureApplicationMenu()
        installApplicationKeyboardShortcuts()
        configureStatusItem()
        observeModel()
        observeLocalization()
        installWorkspaceAudioLifecycleObservers()
        if OnboardingLaunchPolicy.shouldStartRuntime(
            isComplete: model.settings.isOnboardingComplete,
            step: model.settings.onboardingStep
        ) {
            model.startIfNeeded()
        }
        if model.settings.isOnboardingComplete,
           BridgeAppModel.shouldRecoverHIDAfterCompletedUpdate(
            completedUpdate: completedUpdate,
            customMappingEnabled: model.settings.customMappingEnabled
        ) {
            model.recoverHIDAfterCompletedUpdate()
        }
        let shouldOpenPermissionRepair = CompletedUpdatePermissionRepairPolicy.shouldOpenPermissions(
            isOnboardingComplete: model.settings.isOnboardingComplete,
            completedUpdate: completedUpdate,
            bluetoothGranted: CBManager.authorization == .allowedAlways,
            inputMonitoringGranted: HIDRemoteMonitor.isInputMonitoringGranted,
            accessibilityGranted: KeyboardInjector.isAccessibilityTrusted
        )
        if shouldOpenPermissionRepair {
            AppLogger.shared.write(
                "UPDATE PERMISSION_REPAIR bluetooth=\(CBManager.authorization == .allowedAlways) " +
                    "input=\(HIDRemoteMonitor.isInputMonitoringGranted) " +
                    "accessibility=\(KeyboardInjector.isAccessibilityTrusted)"
            )
        }
        refreshMenuStatus()

        if OnboardingLaunchPolicy.shouldShowMainWindow(
            isComplete: model.settings.isOnboardingComplete,
            completedUpdate: completedUpdate,
            openMainWindowAtLaunch: model.settings.openMainWindowAtLaunch
        ) {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if shouldOpenPermissionRepair {
                    self.showSettingsWindow(initialSection: .permissions)
                } else {
                    self.showSettings()
                }
                if completedUpdate {
                    self.showUpdateCompletedAlert()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        terminationSignalSources.forEach { $0.cancel() }
        terminationSignalSources.removeAll()
        if let applicationShortcutMonitor {
            NSEvent.removeMonitor(applicationShortcutMonitor)
            self.applicationShortcutMonitor = nil
        }
        let workspaceNotificationCenter = NSWorkspace.shared.notificationCenter
        workspaceAudioLifecycleObservers.forEach(workspaceNotificationCenter.removeObserver)
        workspaceAudioLifecycleObservers.removeAll()
        AppLogger.shared.write("SYSTEM AUDIO observers_stopped")
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        showSettings()
        return true
    }

    private func installTerminationSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: .main
            )
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    private func installWorkspaceAudioLifecycleObservers() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let events: [(Notification.Name, SystemAudioLifecycleEvent)] = [
            (NSWorkspace.screensDidSleepNotification, .screenDidSleep),
            (NSWorkspace.screensDidWakeNotification, .screenDidWake),
            (NSWorkspace.sessionDidResignActiveNotification, .sessionDidResignActive),
            (NSWorkspace.sessionDidBecomeActiveNotification, .sessionDidBecomeActive),
            (NSWorkspace.willSleepNotification, .systemWillSleep),
            (NSWorkspace.didWakeNotification, .systemDidWake),
        ]
        workspaceAudioLifecycleObservers = events.map { name, event in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.model.handleSystemAudioLifecycle(event)
                    if event == .systemDidWake {
                    }
                }
            }
        }
        AppLogger.shared.write(
            "SYSTEM AUDIO observers_started events=\(events.map { $0.1.rawValue }.joined(separator: ","))"
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenuStatus()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.toolTip = localization.text("app.name")
            button.target = self
            button.action = #selector(handleStatusItemClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            if let image = statusImage(isStreaming: false) {
                button.image = image
            } else {
                button.title = localization.text("status_item.accessibility_label")
            }
        }

        connectionItem.isEnabled = false
        audioItem.isEnabled = false
        hidItem.isEnabled = false

        statusItem = item
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        statusMenu?.removeItem(connectionItem)
        statusMenu?.removeItem(audioItem)
        statusMenu?.removeItem(hidItem)

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(connectionItem)
        menu.addItem(audioItem)
        menu.addItem(hidItem)
        menu.addItem(.separator())
        menu.addItem(menuItem("connection.action.reconnect", action: #selector(reconnect)))
        menu.addItem(menuItem("menu.open_settings", action: #selector(showSettings)))
        menu.addItem(menuItem("menu.show_logs", action: #selector(showLog)))
        menu.addItem(languageMenuItem())
        menu.addItem(.separator())
        menu.addItem(menuItem("menu.about", action: #selector(showAbout)))
        menu.addItem(versionMenuItem())
        menu.addItem(menuItem("menu.check_for_updates", action: #selector(checkForUpdates)))
        menu.addItem(menuItem("about.support.github", action: #selector(openGitHub)))
        menu.addItem(menuItem("about.support.website", action: #selector(openWebsite)))
        menu.addItem(.separator())
        menu.addItem(menuItem("common.action.quit", action: #selector(quit)))
        statusMenu = menu
        refreshMenuStatus()
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: localization.text("app.name"))
        let quitItem = NSMenuItem(
            title: localization.text("common.action.quit"),
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = .command
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: localization.text("menu.file"))
        let closeItem = NSMenuItem(
            title: localization.text("common.action.close"),
            action: #selector(closeKeyWindow),
            keyEquivalent: "w"
        )
        closeItem.keyEquivalentModifierMask = .command
        closeItem.target = self
        fileMenu.addItem(menuItem("menu.open_log_folder", action: #selector(showLog)))
        fileMenu.addItem(.separator())
        fileMenu.addItem(closeItem)
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func installApplicationKeyboardShortcuts() {
        applicationShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            let relevantModifiers = event.modifierFlags.intersection([
                .command, .control, .option, .shift,
            ])
            guard relevantModifiers == .command else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "q":
                self?.quit()
                return nil
            case "w":
                self?.closeKeyWindow()
                return nil
            default:
                return event
            }
        }
    }

    private func menuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: localization.text(title), action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func languageMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: localization.text("menu.language"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in AppLanguage.allCases {
            let title: String
            switch language {
            case .system:
                title = localization.text("language.system")
            case .simplifiedChinese, .english:
                title = language.nativeDisplayName
            }
            let languageItem = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            languageItem.target = self
            languageItem.representedObject = language.rawValue
            languageItem.state = language == localization.language ? .on : .off
            submenu.addItem(languageItem)
        }
        item.submenu = submenu
        return item
    }

    private func versionMenuItem() -> NSMenuItem {
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? localization.text("common.value.unknown")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let title = build.map {
            String(
                format: localization.text("app.version_with_build"),
                locale: localization.locale,
                arguments: [shortVersion, $0]
            )
        } ?? String(
            format: localization.text("app.version"),
            locale: localization.locale,
            arguments: [shortVersion]
        )
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func observeModel() {
        Publishers.CombineLatest4(
            model.$connectionStatus,
            model.$audioStatus,
            model.$hidStatus,
            model.$isStreaming
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
            self?.refreshMenuStatus()
        }
        .store(in: &subscriptions)

    }

    private func observeLocalization() {
        localization.$locale
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.statusItem?.button?.toolTip = self.localization.text("app.name")
                self.settingsWindowController?.window?.title = self.localization.text("app.name")
                self.configureApplicationMenu()
                self.rebuildStatusMenu()
                self.updateInformation.reloadReleaseNotes(
                    localeIdentifier: self.localization.locale.identifier
                )
            }
            .store(in: &subscriptions)
    }

    private func configureUpdater() {
        startUpdaterIfNeeded()
    }

    private func startUpdaterIfNeeded() {
        guard !updaterStarted else { return }
        _ = updaterController
        updaterStarted = true
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        updateFeedSelection.feedURLString()
    }

    private func refreshMenuStatus() {
        connectionItem.title = model.connectionStatus.text(using: localization)
        audioItem.title = model.isStreaming
            ? localization.text("connection.status.voice_active")
            : model.audioStatus.text(using: localization)
        hidItem.title = model.hidStatus.text(using: localization)
        statusItem?.button?.image = statusImage(isStreaming: model.isStreaming)
    }

    private func statusImage(isStreaming: Bool) -> NSImage? {
        let resourceName = isStreaming ? "StatusIconActiveTemplate" : "StatusIconTemplate"
        let fallbackSymbol = isStreaming ? "mic.fill" : "dot.radiowaves.left.and.right"
        let accessibilityDescription = localization.text(
            isStreaming ? "status_item.voice_active_accessibility" : "status_item.accessibility_label"
        )
        let image = NSImage(named: NSImage.Name(resourceName))
            ?? NSImage(
                systemSymbolName: fallbackSymbol,
                accessibilityDescription: accessibilityDescription
            )
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        image?.accessibilityDescription = accessibilityDescription
        return image
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            showSettings()
        }
    }

    private func showStatusMenu() {
        guard let statusItem, let statusMenu else { return }
        refreshMenuStatus()
        statusItem.menu = statusMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func reconnect() {
        model.reconnect()
    }

    @objc private func showSettings() {
        showSettingsWindow(initialSection: .connection)
    }

    private func showSettingsWindow(initialSection: SettingsSection) {
        if settingsWindowController == nil {
            settingsWindowController = makeSettingsWindowController(
                initialSettingsSection: initialSection
            )
        }
        guard let windowController = settingsWindowController,
              let window = windowController.window else { return }
        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindowController(
        initialSettingsSection: SettingsSection = .connection
    ) -> NSWindowController {
        let hostingController = NSHostingController(
            rootView: RemoteMicRootView(
                model: model,
                updateInformation: updateInformation,
                checkForUpdates: { [weak self] in self?.checkForUpdates() },
                refreshUpdateInformation: { [weak self] in
                    self?.refreshUpdateInformation()
                },
                setDockIconVisible: { [weak self] isVisible in
                    self?.setDockIconVisible(isVisible)
                },
                initialSettingsSection: initialSettingsSection
            )
            .environmentObject(localization)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 772),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = localization.text("app.name")
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 1020, height: 772)
        window.setFrameAutosaveName("RemoteMicSettings")
        window.center()
        return NSWindowController(window: window)
    }

    @objc private func showLog() {
        model.openLogFolder()
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let shortVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? localization.text("common.value.unknown")
        let alert = NSAlert()
        alert.messageText = localization.text("app.name")
        alert.informativeText = String(
            format: localization.text("about.alert.description_with_version"),
            locale: localization.locale,
            arguments: [shortVersion]
        )
        alert.addButton(withTitle: localization.text("common.action.ok"))
        alert.runModal()
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let language = AppLanguage(rawValue: rawValue)
        else { return }
        localization.select(language)
    }

    @objc private func checkForUpdates() {
        performUpdateCheck(.userInitiated)
    }

    private func refreshUpdateInformation() {
        performUpdateCheck(.information)
    }

    private func performUpdateCheck(_ purpose: UpdateCheckPurpose) {
        startUpdaterIfNeeded()
        guard !updaterController.updater.sessionInProgress else { return }
        switch purpose {
        case .information:
            updateInformation.beginChecking()
            updaterController.updater.checkForUpdateInformation()
        case .userInitiated:
            updaterController.checkForUpdates(nil)
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateInformation.setAvailable(
            displayVersion: item.displayVersionString,
            buildVersion: item.versionString,
            archiveURL: item.fileURL,
            fallbackDescription: item.itemDescription,
            localeIdentifier: localization.locale.identifier
        )
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateInformation.setUpToDate()
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        if error != nil, updateInformation.state == .checking {
            updateInformation.setUnavailable()
        }
    }

    private func showUpdateCompletedAlert() {
        guard let window = settingsWindowController?.window else { return }
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? localization.text("common.value.unknown")
        let alert = NSAlert()
        alert.messageText = localization.text("update.completed.title")
        alert.informativeText = String(
            format: localization.text("update.completed.message"),
            locale: localization.locale,
            arguments: [version]
        )
        alert.addButton(withTitle: localization.text("common.action.ok"))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func setDockIconVisible(_ isVisible: Bool) {
        model.settings.showDockIcon = isVisible
        NSApp.setActivationPolicy(isVisible ? .regular : .accessory)
        if isVisible {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(AppLinks.githubRepository)
    }

    @objc private func openWebsite() {
        NSWorkspace.shared.open(localization.localizedWebsiteURL)
    }

    @objc private func closeKeyWindow() {
        NSApp.keyWindow?.performClose(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
