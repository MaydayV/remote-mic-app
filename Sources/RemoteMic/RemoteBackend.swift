//
//  RemoteBackend.swift
//  RemoteMic
//
//  遥控器后端统一抽象：每种实体遥控器（小米蓝牙遥控器 2 Pro / Apple TV Siri Remote）
//  实现一个 Backend，向 BridgeAppModel 暴露统一的按键与音频事件。
//

import Foundation

/// 遥控器后端统一协议。
///
/// 设计目标：BridgeAppModel 与设置页只依赖本协议，不感知具体遥控器型号；
/// 新增遥控器只需实现一个新的 Backend，不改动 UI 与按键映射逻辑。
protocol RemoteBackend: AnyObject {
    /// 设备显示名（如 "Apple Siri Remote"）
    var deviceName: String { get }

    /// 当前电量百分比（0-100），不可读时为 nil
    var batteryLevel: Int? { get }

    /// 该后端支持的按键集合（用于 UI 过滤，避免把 Siri 专用键显示在小米遥控器映射画布上）
    var supportedButtons: [RemoteButton] { get }

    func start()
    func stop()

    func startMicrophone()
    func stopMicrophone()

    /// 已解码音频样本（Float 归一化 [-1, 1]），参数为采样率（Hz）
    /// 小米后端：16 kHz；Siri Remote 后端：48 kHz（动态采样率由上层 VirtualAudioOutput 处理）
    var onAudioSamples: (([Float], Double) -> Void)? { get set }

    /// 按键事件：`onButton(button, isPressed)`，按下 true / 抬起 false
    var onButton: ((RemoteButton, Bool) -> Void)? { get set }
}

/// 触摸事件接口（预留）。
///
/// 现状：macOS 无法从 HID 报告获取 Siri Remote 触摸板坐标——持有遥控器 HID 接口时，
/// 私有 MultitouchSupport 框架返回零触摸帧，且 HID 输入报告只包含 0xFB 按键掩码
/// （VibeRemote 已验证）。本枚举先定义接口，实现挂起，不影响按键功能。
enum RemoteTouchEvent {
    case swipeUp
    case swipeDown
    case swipeLeft
    case swipeRight
    case circularScrollCW
    case circularScrollCCW
    case touchMove(x: Float, y: Float)
    case touchClick
}

/// 遥控器类型（设置页"连接设备"选择）。
enum RemoteBackendKind: String, Codable, CaseIterable, Identifiable {
    case xiaomi = "xiaomi_2_pro"
    case siriRemote = "siri_remote_3"

    var id: String { rawValue }

    /// 默认后端：小米（保持现有行为）
    static let `default` = RemoteBackendKind.xiaomi

    var supportedButtons: [RemoteButton] {
        switch self {
        case .xiaomi:
            return RemoteButton.allCases.filter {
                switch $0 {
                case .playPause, .mute, .voice: return false
                default: return true
                }
            }
        case .siriRemote:
            return [
                .power, .up, .left, .ok, .right, .down, .back,
                .volumeUp, .volumeDown, .tv,
                .playPause, .mute, .voice,
            ]
        }
    }
}

enum RemoteAudioFormat {
    static let xiaomiSampleRate: Double = 16_000
    static let siriRemoteSampleRate: Double = 48_000

    static func needsReconfiguration(current: Double, incoming: Double) -> Bool {
        incoming > 0 && abs(current - incoming) > 0.5
    }
}

enum RemoteBackendRuntimePolicy {
    static func shouldRunSiriRemote(activeKind: RemoteBackendKind) -> Bool {
        activeKind == .siriRemote
    }
}
