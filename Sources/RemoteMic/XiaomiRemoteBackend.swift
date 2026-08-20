//
//  XiaomiRemoteBackend.swift
//  RemoteMic
//
//  小米蓝牙遥控器 2 Pro 后端。
//
//  适配策略（渐进式，避免破坏稳定链路）：小米的蓝牙/ATVV/HID 链路仍由 BridgeAppModel
//  直接管理，本类作为统一 RemoteBackend 入口接收事件镜像（按键/音频/电量），
//  使上层（设置页、未来的多后端调度）能以统一协议访问小米遥控器，而小米路径零行为变化。
//

import Foundation

final class XiaomiRemoteBackend: RemoteBackend {
    let deviceName = "小米蓝牙遥控器 2 Pro"

    /// 小米遥控器的按键集 = 历史 12 键（Siri Remote 新增的 playPause/mute/voice 不出现）
    let supportedButtons = RemoteBackendKind.xiaomi.supportedButtons

    private(set) var batteryLevel: Int?

    var onAudioSamples: (([Float], Double) -> Void)?
    var onButton: ((RemoteButton, Bool) -> Void)?

    // 小米链路生命周期由 BridgeAppModel 管理；backend 不重复启停。
    func start() {}
    func stop() {}
    func startMicrophone() {}
    func stopMicrophone() {}

    // MARK: - 桥接入口（BridgeAppModel 调用）

    /// HID 按键事件转发（按下/抬起两相）
    func forwardButton(_ button: RemoteButton, isPressed: Bool) {
        onButton?(button, isPressed)
    }

    /// ATVV 解码音频转发（16 kHz Int16 → 归一化 Float）
    func forwardAudio(samples: [Int16], sampleRate: Double = RemoteAudioFormat.xiaomiSampleRate) {
        guard samples.count > 0 else { return }
        let floats = samples.map { Float($0) / 32768.0 }
        onAudioSamples?(floats, sampleRate)
    }

    /// 电量更新
    func updateBatteryLevel(_ level: Int?) {
        batteryLevel = level
    }
}
