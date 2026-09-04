import Foundation
import AppKit
import SwiftUI
import Testing
@testable import RemoteMic

@Suite("Settings page regression")
struct SettingsPageRegressionTests {
    @Test func removedPhoneAppConnectionIsAbsentFromTheApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let modelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/BridgeAppModel.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(!modelSource.contains("PhoneRemote"))
        #expect(!modelSource.contains("WebRemote"))
        #expect(!settingsSource.contains("connection.phone."))
        #expect(!settingsSource.contains("connection.web."))
        #expect(!settingsSource.contains("WebRemoteSessionView"))
    }

    @Test func settingsWindowDragsOnlyFromDedicatedTopArea() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains("window.isMovableByWindowBackground = false"))
        #expect(!appSource.contains("window.isMovableByWindowBackground = true"))
        #expect(settingsSource.contains("WindowDragArea()"))
        #expect(settingsSource.contains("window?.performDrag(with: event)"))
    }

    @Test func closingSettingsCanHideDockIconWhileKeepingTheMenuBarAppAlive() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )

        #expect(appSource.contains("window.hidesOnDeactivate = false"))
        #expect(appSource.contains("window.delegate = self"))
        #expect(appSource.contains("func windowWillClose(_ notification: Notification)"))
        #expect(appSource.contains("isSettingsWindowOpen = false"))
        #expect(appSource.contains("updateDockActivationPolicy()"))

        #expect(SettingsWindowActivationPolicy.value(
            showDockIcon: false,
            isSettingsWindowOpen: true
        ) == .regular)
        #expect(SettingsWindowActivationPolicy.value(
            showDockIcon: false,
            isSettingsWindowOpen: false
        ) == .accessory)
        #expect(SettingsWindowActivationPolicy.value(
            showDockIcon: true,
            isSettingsWindowOpen: false
        ) == .regular)
    }

    @Test func siriRemoteBackendChoiceUsesTheRealRemotePhoto() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(settingsSource.contains("kind == .siriRemote, let photo = SiriRemoteImageResource.image"))
        #expect(settingsSource.contains("forResource: \"SiriRemote-photo\""))
        #expect(settingsSource.contains("Image(nsImage: photo)"))
        #expect(settingsSource.contains("Image(systemName: icon)"))
    }

    @Test func compatibilityDriverHasInlineInstallAndUninstallControls() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(settingsSource.contains("model.installDoubaoDriver()"))
        #expect(settingsSource.contains("model.uninstallDoubaoDriver()"))
        #expect(settingsSource.contains("driver_operation_failed"))
    }

    @Test func loginItemPreferenceUsesNativeServiceAndHasRecoveryCopy() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/LoginItemService.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        #expect(serviceSource.contains("SMAppService.mainApp"))
        #expect(settingsSource.contains("about.preferences.launch_at_login"))
        #expect(settingsSource.contains("openLoginItemsSettings"))
    }

    @Test func mappingSelectionStaysOnTheEditedButtonWhileLocked() {
        #expect(MappingSelectionPolicy.selection(
            current: .home,
            activeButtons: [.menu],
            isLocked: true
        ) == .home)
        #expect(MappingSelectionPolicy.selection(
            current: .home,
            activeButtons: [.menu],
            isLocked: false
        ) == .menu)
        #expect(MappingSelectionPolicy.selection(
            current: .home,
            activeButtons: [],
            isLocked: false
        ) == .home)
    }

    @Test func customMappingPromptsOnlyWhenAnEnabledPermissionIsMissing() {
        #expect(MappingPermissionPolicy.requiresPrompt(
            enabled: true,
            inputMonitoringGranted: false,
            accessibilityGranted: true
        ))
        #expect(MappingPermissionPolicy.requiresPrompt(
            enabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: false
        ))
        #expect(!MappingPermissionPolicy.requiresPrompt(
            enabled: true,
            inputMonitoringGranted: true,
            accessibilityGranted: true
        ))
        #expect(!MappingPermissionPolicy.requiresPrompt(
            enabled: false,
            inputMonitoringGranted: false,
            accessibilityGranted: false
        ))
    }

    @Test func remoteMappingLayoutCoversEveryRealButtonWithExactConnectorAnchors() throws {
        let placements = RemoteMappingLayout.buttonPlacements
        // 映射画布呈现小米遥控器（RC003）的 12 键布局；Siri Remote 专用键不在画布上
        let xiaomiButtons = Set(RemoteButton.allCases).subtracting([.playPause, .mute, .voice])
        #expect(placements.count == xiaomiButtons.count)
        #expect(Set(placements.map(\.button)) == xiaomiButtons)

        let expectedAnchors: [RemoteButton: UnitPoint] = [
            .power: UnitPoint(x: 0.386, y: 0.099),
            .up: UnitPoint(x: 0.502, y: 0.179),
            .left: UnitPoint(x: 0.362, y: 0.246),
            .ok: UnitPoint(x: 0.502, y: 0.246),
            .right: UnitPoint(x: 0.638, y: 0.246),
            .down: UnitPoint(x: 0.502, y: 0.317),
            .back: UnitPoint(x: 0.406, y: 0.389),
            .volumeUp: UnitPoint(x: 0.604, y: 0.390),
            .home: UnitPoint(x: 0.406, y: 0.479),
            .volumeDown: UnitPoint(x: 0.604, y: 0.480),
            .menu: UnitPoint(x: 0.406, y: 0.569),
            .tv: UnitPoint(x: 0.604, y: 0.569),
        ]
        for placement in placements {
            let expected = expectedAnchors[placement.button]
            #expect(placement.anchor.x == expected?.x)
            #expect(placement.anchor.y == expected?.y)
            #expect((0...1).contains(placement.targetY))
        }

        let canvasWidth: CGFloat = 866
        let cardWidth: CGFloat = 250
        let leftEnd = RemoteMappingLayout.cardEdgePoint(
            side: .left,
            targetY: 0.5,
            canvasWidth: canvasWidth,
            cardWidth: cardWidth
        )
        let rightEnd = RemoteMappingLayout.cardEdgePoint(
            side: .right,
            targetY: 0.5,
            canvasWidth: canvasWidth,
            cardWidth: cardWidth
        )
        #expect(leftEnd == CGPoint(x: cardWidth, y: RemoteMappingLayout.canvasHeight / 2))
        #expect(rightEnd == CGPoint(x: canvasWidth - cardWidth, y: RemoteMappingLayout.canvasHeight / 2))
        #expect(RemoteMappingLayout.voiceAnchor == UnitPoint(x: 0.630, y: 0.099))
        #expect(RemoteMappingLayout.appleButtonPlacements.count == 12)
        #expect(!RemoteMappingLayout.appleButtonPlacements.contains { $0.button == .home || $0.button == .menu })
        #expect(RemoteMappingLayout.appleVoiceAnchor == UnitPoint(x: 0.50, y: 0.128))
        #expect(RemoteMappingLayout.siriRemoteScale > 1)
        #expect(RemoteMappingLayout.cardWidth(for: canvasWidth) == 300)

        let appleLeftTargets = RemoteMappingLayout.appleButtonPlacements
            .filter { $0.side == .left }
            .map(\.targetY)
        let appleRightTargets = RemoteMappingLayout.appleButtonPlacements
            .filter { $0.side == .right }
            .map(\.targetY)
        #expect(appleLeftTargets.last == 0.90)
        #expect(appleRightTargets.last == 0.90)
        #expect((appleLeftTargets[1] - appleLeftTargets[0]) > (appleRightTargets[1] - appleRightTargets[0]))

        let unscaledPower = RemoteMappingLayout.remotePoint(
            for: RemoteMappingLayout.appleButtonPlacements[0].anchor,
            canvasWidth: canvasWidth
        )
        let scaledPower = RemoteMappingLayout.remotePoint(
            for: RemoteMappingLayout.appleButtonPlacements[0].anchor,
            canvasWidth: canvasWidth,
            imageScale: RemoteMappingLayout.siriRemoteScale
        )
        #expect(scaledPower.x > unscaledPower.x)

        let menuPlacement = try #require(placements.first { $0.button == .menu })
        let tvPlacement = try #require(placements.first { $0.button == .tv })
        let homePlacement = try #require(placements.first { $0.button == .home })
        let volumeDownPlacement = try #require(placements.first { $0.button == .volumeDown })
        #expect(menuPlacement.side == .left)
        #expect(tvPlacement.side == .right)
        #expect(homePlacement.side == .left)
        #expect(volumeDownPlacement.side == .right)

        for side in [RemoteMappingSide.left, .right] {
            let orderedAnchors = placements
                .filter { $0.side == side }
                .sorted { $0.targetY < $1.targetY }
                .map(\.anchor.y)
            #expect(zip(orderedAnchors, orderedAnchors.dropFirst()).allSatisfy { $0 <= $1 })
        }

        let start = CGPoint(x: canvasWidth / 2, y: 100)
        let leftEndPoint = CGPoint(x: 285, y: 160)
        let leftControls = RemoteMappingLayout.connectionControlPoints(
            start: start,
            end: leftEndPoint,
            side: .left
        )
        #expect(leftControls.start.x < start.x)
        #expect(leftControls.end.x > leftEndPoint.x)

        let rightEndPoint = CGPoint(x: canvasWidth - 285, y: 160)
        let rightControls = RemoteMappingLayout.connectionControlPoints(
            start: start,
            end: rightEndPoint,
            side: .right
        )
        #expect(rightControls.start.x > start.x)
        #expect(rightControls.end.x < rightEndPoint.x)

        #expect(RemoteMappingLayout.arrowTip(cardEdge: leftEndPoint, side: .left).x == leftEndPoint.x + 7)
        #expect(RemoteMappingLayout.arrowTip(cardEdge: rightEndPoint, side: .right).x == rightEndPoint.x - 7)
    }

    @Test func redesignedPagesKeepEveryExistingUserAction() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let mappingCanvasSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMappingCanvas.swift"),
            encoding: .utf8
        )
        let source = settingsSource + mappingCanvasSource

        for requiredAction in [
            "model.reconnect()",
            "model.applyAudioSettings()",
            "model.refreshAudioDevices()",
            "model.sendTestTone()",
            "model.selectDoubaoAudioDevice()",
            "model.openDoubaoDriverInstructions(using: localization)",
            "model.setVoiceFnTapModeEnabled",
            "settings.setAction(action, for: button, trigger: trigger)",
            "settings.setShortcut(",
            "chooseCustomApplication(for:",
            "recordCustomApplicationInput(profileID:",
            "settings.setApplicationProfileID(",
            ".openCustomApplication",
            "settings.resetBindings()",
        ] {
            #expect(source.contains(requiredAction), Comment(rawValue: requiredAction))
        }

        #expect(!source.contains("connection.phone."))
        #expect(!source.contains("connection.web."))
        #expect(source.contains("ButtonTrigger.allCases"))
        #expect(source.contains("isMappingSelectionLocked"))
        #expect(!source.contains("ScrollView(.horizontal, showsIndicators: false)"))
        #expect(!source.contains("remoteDeviceBindingPanel"))
        #expect(!source.contains("SidebarGlassModifier"))
        #expect(source.contains(".focusEffectDisabled()"))
        #expect(source.contains(".frame(height: 56)"))
        #expect(source.contains(".ignoresSafeArea(.container, edges: .top)"))
        #expect(source.contains("showsAnchor: activeButtons.contains(placement.button)"))
        #expect(source.contains(".toggleStyle(.switch)"))
        #expect(source.contains("button_mapping.permission_prompt.open"))
        #expect(source.contains("button_mapping.selection_lock_hint_short"))
        #expect(source.contains("connection.voice_fn_tap.hint_short"))
        #expect(source.contains("ButtonActionCategory.allCases"))
        #expect(source.contains("LazyVGrid("))
        #expect(source.contains("button_mapping.action.disable_switch"))
        #expect(source.contains(").filter { $0 != .disabled }"))
        #expect(source.contains("DisclosureGroup(isExpanded: $isPresetApplicationActionsExpanded)"))
        #expect(source.contains("isPresetApplicationActionsExpanded = false"))
        #expect(source.contains("custom_application.accessibility.learn_help"))
        #expect(!source.contains(".popover(item: $mappingEditingTarget)"))
        #expect(!source.contains(".sheet(item: $shortcutEditingTarget)"))
        #expect(!source.contains("ApplicationShortcutEditorSheet"))
        #expect(source.contains("shortcut.editor.click_first_help"))
        #expect(source.contains("shortcut.editor.recording_prompt"))
        #expect(source.contains("shortcut.editor.success"))
        #expect(!source.contains("NSEvent.addLocalMonitorForEvents(matching: .keyDown)"))
        #expect(!mappingCanvasSource.contains("size: 8"))
        #expect(!mappingCanvasSource.contains("size: 9"))
        #expect(!mappingCanvasSource.contains("size: 10"))
        #expect(!mappingCanvasSource.contains("size: 11"))
        #expect(!mappingCanvasSource.contains("minimumScaleFactor"))
        #expect(source.range(of: "MappingRemotePhoto(")!.lowerBound < source.range(of: "connectionLines(metrics: metrics)")!.lowerBound)

        let voiceFnToggle = "Toggle(\"connection.voice_fn_tap.enabled\""
        #expect(source.components(separatedBy: voiceFnToggle).count == 2)
        #expect(
            source.range(of: voiceFnToggle)!.lowerBound >
                source.range(of: "private var mappingPage")!.lowerBound
        )
    }

    @Test func remoteCardsShowCompleteNamesWithoutDuplicateConnectionSummary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )
        let appSource = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/RemoteMicApp.swift"),
            encoding: .utf8
        )
        let chinese = try String(
            contentsOf: root.appendingPathComponent("Resources/zh-Hans.lproj/Localizable.strings"),
            encoding: .utf8
        )
        let english = try String(
            contentsOf: root.appendingPathComponent("Resources/en.lproj/Localizable.strings"),
            encoding: .utf8
        )

        #expect(chinese.contains(#""remote.device.model.rc001" = "小米蓝牙遥控器 2";"#))
        #expect(chinese.contains(#""remote.device.model.rc003" = "小米蓝牙遥控器 2 Pro";"#))
        #expect(english.contains(#""remote.device.model.rc001" = "Xiaomi Bluetooth Remote 2";"#))
        #expect(english.contains(#""remote.device.model.rc003" = "Xiaomi Bluetooth Remote 2 Pro";"#))

        let cardStart = try #require(settingsSource.range(of: "private func remoteDeviceCard"))
        let cardEnd = try #require(settingsSource.range(
            of: "private func batterySymbol",
            range: cardStart.upperBound..<settingsSource.endIndex
        ))
        let cardSource = settingsSource[cardStart.lowerBound..<cardEnd.lowerBound]
        #expect(cardSource.contains("ViewThatFits(in: .horizontal)"))
        #expect(cardSource.contains("fillsWidth ? nil : 232"))
        #expect(cardSource.contains("remoteBatteryLabel("))
        #expect(cardSource.contains("powerState: model.powerState(for: profile.id)"))
        #expect(cardSource.contains("Image(systemName: \"bolt.fill\")"))
        #expect(!cardSource.contains("Label(power.text"))
        #expect(!cardSource.contains("remote.device.power.rechargeable"))
        for symbol in [
            "battery.0percent",
            "battery.25percent",
            "battery.50percent",
            "battery.75percent",
            "battery.100percent",
        ] {
            #expect(settingsSource.contains(symbol))
        }
        #expect(settingsSource.contains("if level <= 10 { return .red }"))
        #expect(settingsSource.contains("if level <= 25 { return .orange }"))

        let panelStart = try #require(settingsSource.range(of: "private var connectionDevicePanel"))
        let panelEnd = try #require(settingsSource.range(
            of: "private var mappingPage",
            range: panelStart.upperBound..<settingsSource.endIndex
        ))
        let panelSource = settingsSource[panelStart.lowerBound..<panelEnd.lowerBound]
        #expect(!panelSource.contains("Text(selectedRemoteDisplayName)"))
        #expect(!panelSource.contains("StatusPill(text: connectionBadge"))

        #expect(appSource.contains(
            "fileMenu.addItem(menuItem(\"menu.open_log_folder\", action: #selector(showLog)))"
        ))
    }

    @Test func siriRemotePagesUseTheirOwnLocalizedDevicePresentation() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(source.contains("Text(localization.text(titleKey))"))
        #expect(source.contains("Text(localization.text(detailKey))"))
        #expect(source.contains("private var siriRemoteConnectionPanel"))
        #expect(source.contains("private var siriRemoteMappingStatusCard"))
        #expect(source.contains("if model.activeBackendKind == .siriRemote"))
        #expect(source.contains("RemoteBackendKind.siriRemote.supportedButtons.filter"))
        #expect(source.contains("minHeight: 102, maxHeight: 102"))
        #expect(source.contains("remote.backend.xiaomi_voice_hint"))
        #expect(!source.contains(".font(.caption2"))
        for size in [8, 9, 10, 11] {
            #expect(!source.contains(".font(.system(size: \(size)"))
        }
    }

    @Test func aboutPageKeepsVersionFeaturesTogetherAndLanguagesVisible() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        let aboutPage = try #require(source.components(separatedBy: "private var aboutPage").last)
        #expect(aboutPage.contains("updateInformationContent"))
        #expect(aboutPage.contains("about.version.history"))
        #expect(!aboutPage.contains("about.version.check_prerelease"))
        #expect(aboutPage.contains("about.version.update_to"))
        #expect(aboutPage.contains("ForEach(AppLanguage.allCases)"))
        #expect(aboutPage.contains(".pickerStyle(.segmented)"))
        #expect(!aboutPage.contains("help.glossary.open"))
        #expect(!aboutPage.contains("openGlossary"))
    }

    @Test func settingsDoNotContainPrivateFeatureIntegration() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/RemoteMic/SettingsView.swift"),
            encoding: .utf8
        )

        #expect(!source.contains("PrivateFeature"))
        #expect(!source.contains("SayAllAI"))
        #expect(!source.contains("deepSeek"))
        #expect(!source.contains("postDictation"))
    }
}
