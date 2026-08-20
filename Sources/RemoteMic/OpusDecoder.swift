//
//  OpusDecoder.swift
//  RemoteMic
//
//  Siri Remote 麦克风音频解码器。
//
//  协议参数（VibeRemote / siri-remote 交叉验证）：
//  - Opus CELT（仅 CELT 模式），48 kHz mono，960 samples/frame（20ms）
//  - HID report 0xFA，99-byte payload
//  - 解码使用系统 AudioToolbox 的 kAudioFormatOpus（macOS 11+ 内置），无第三方依赖。
//

import AVFoundation
import Foundation

enum OpusDecoderError: Error {
    case sourceFormatUnavailable
    case pcmFormatUnavailable
    case converterUnavailable
    case decodeFailed(String)
}

/// 将 Siri Remote 的 Opus CELT 帧解码为 48 kHz Float32 PCM。
final class OpusDecoder {
    private let pcmFormat: AVAudioFormat
    private let converter: AVAudioConverter

    init() throws {
        var opusDescription = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 960,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let sourceFormat = AVAudioFormat(streamDescription: &opusDescription),
              let pcmFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
              )
        else {
            throw OpusDecoderError.sourceFormatUnavailable
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: pcmFormat) else {
            throw OpusDecoderError.converterUnavailable
        }
        self.pcmFormat = pcmFormat
        self.converter = converter
    }

    /// 解码单个 Opus 包。返回 48 kHz Float32 单声道样本；包为空返回 nil。
    func decode(_ packet: Data) throws -> [Float]? {
        guard !packet.isEmpty else { return nil }

        let compressed = AVAudioCompressedBuffer(
            format: converter.inputFormat,
            packetCapacity: 1,
            maximumPacketSize: packet.count
        )
        compressed.packetCount = 1
        compressed.byteLength = UInt32(packet.count)
        packet.withUnsafeBytes { bytes in
            guard let source = bytes.baseAddress else { return }
            memcpy(compressed.data, source, packet.count)
        }
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 960,
            mDataByteSize: UInt32(packet.count)
        )

        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 5_760) else {
            throw OpusDecoderError.pcmFormatUnavailable
        }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, state in
            if supplied {
                state.pointee = .noDataNow
                return nil
            }
            supplied = true
            state.pointee = .haveData
            return compressed
        }
        if status == .error {
            throw OpusDecoderError.decodeFailed(
                conversionError?.localizedDescription ?? "unknown error"
            )
        }
        guard output.frameLength > 0, let channel = output.floatChannelData?[0] else {
            return nil
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// 0xFA 99-byte HID 麦克风报告解析器（纯逻辑，可单测）。
///
/// Gen-3 Direct HID 布局（99 bytes）：
///   bytes[0..2]  前缀
///   bytes[2..4]  little-endian 序号
///   bytes[4]     Opus 包长度
///   bytes[5..5+len]  Opus 包（剩余为零填充）
///   长度 0 = 按钮释放哨兵
/// 兼容旧代 1B 35 封装（PacketLogger 时代）。
enum SiriRemoteAudioReportParser {
    enum Event: Equatable {
        case packet(Data)
        case ended
    }

    /// 从原始报告字节中提取音频事件。
    /// - Parameters:
    ///   - bytes: HID 报告原始字节（可能带 macOS 合成的 0xFF report ID 前缀）
    static func events(from bytes: [UInt8]) -> [Event] {
        var bytes = bytes
        // macOS 可能在回调缓冲中包含合成的 0xFF report ID；99 字节负载只去掉无歧义前缀
        if bytes.count == 100, bytes.first == 0xFF {
            bytes.removeFirst()
        }

        // Gen-3 直接布局
        if bytes.count == 99 {
            let packetLength = Int(bytes[4])
            if packetLength == 0 {
                return [.ended]
            }
            guard packetLength <= 94, 5 + packetLength <= bytes.count else { return [] }
            let packet = Data(bytes[5..<(5 + packetLength)])
            guard packet.contains(where: { $0 != 0 }) else { return [] }
            return [.packet(packet)]
        }

        // 旧代 1B 35 封装兼容
        var output: [Event] = []
        var offset = 0
        while offset + 1 < bytes.count {
            guard bytes[offset] == 0x1B else {
                offset += 1
                continue
            }
            if bytes[offset + 1] == 0x35 {
                guard offset + 7 < bytes.count else { return output }
                let packetLength = Int(bytes[offset + 7])
                let end = offset + 8 + packetLength
                guard packetLength > 0, end <= bytes.count else {
                    offset += 1
                    continue
                }
                let packet = Data(bytes[(offset + 8)..<end])
                if packet.contains(where: { $0 != 0 }) {
                    output.append(.packet(packet))
                }
                offset = end
            } else {
                offset += 1
            }
        }
        return output
    }
}
