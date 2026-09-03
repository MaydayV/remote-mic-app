import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Feeds the Mac's physical input into the selected virtual microphone while
/// Siri Remote voice is idle.  This is the app-level fallback for hosts where
/// the system HCI capture path is unavailable; it never changes the default
/// input device and stops cleanly when Siri Remote is deselected.
final class SiriRemoteBuiltinMicFallback {
    typealias AudioHandler = ([Float], Double) -> Void

    var onAudioSamples: AudioHandler?
    var onStateChange: ((Bool) -> Void)?
    var onDiagnostics: ((String) -> Void)?

    private let queue = DispatchQueue(label: "RemoteMic.siri-builtin-mic-fallback", qos: .userInitiated)
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    private var running = false

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func startOnQueue() {
        guard !running else { return }
        let permission = AVAudioApplication.shared.recordPermission
        if permission == .undetermined {
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                guard let self else { return }
                self.queue.async {
                    if granted {
                        self.startOnQueue()
                    } else {
                        self.emit("SIRI REMOTE builtin fallback unavailable reason=microphone_permission_denied")
                        self.onStateChange?(false)
                    }
                }
            }
            return
        }
        guard permission == .granted else {
            emit("SIRI REMOTE builtin fallback unavailable reason=microphone_permission_required")
            onStateChange?(false)
            return
        }

        let audioEngine = AVAudioEngine()
        let input = audioEngine.inputNode
        guard let builtInDevice = CoreAudioDeviceCatalog.builtInInputDevice(),
              let inputUnit = input.audioUnit
        else {
            emit("SIRI REMOTE builtin fallback unavailable reason=builtin_input_not_found")
            onStateChange?(false)
            return
        }
        var deviceID = builtInDevice.id
        let deviceResult = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceResult == noErr else {
            emit("SIRI REMOTE builtin fallback unavailable reason=select_builtin_failed error=\(deviceResult)")
            onStateChange?(false)
            return
        }
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            emit("SIRI REMOTE builtin fallback unavailable reason=input_format_unavailable")
            onStateChange?(false)
            return
        }
        let converter = format.sampleRate == outputFormat.sampleRate && format.channelCount == 1
            ? nil
            : AVAudioConverter(from: format, to: outputFormat)
        guard (format.sampleRate == outputFormat.sampleRate && format.channelCount == 1) || converter != nil else {
            emit("SIRI REMOTE builtin fallback unavailable reason=converter_unavailable")
            onStateChange?(false)
            return
        }
        // Keep the converter alive for the tap lifetime. The tap callback may
        // run off this object's serial queue, so capture this immutable local
        // instead of reading mutable state concurrently during teardown.
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 960, format: format) { [weak self] buffer, _ in
            guard let self, buffer.frameLength > 0 else { return }
            if let converter {
                let capacity = AVAudioFrameCount(
                    ceil(Double(buffer.frameLength) * self.outputFormat.sampleRate / format.sampleRate) + 1
                )
                guard let output = AVAudioPCMBuffer(pcmFormat: self.outputFormat, frameCapacity: capacity) else { return }
                var supplied = false
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { _, state in
                    if supplied {
                        state.pointee = .noDataNow
                        return nil
                    }
                    supplied = true
                    state.pointee = .haveData
                    return buffer
                }
                guard status != .error, output.frameLength > 0,
                      let channel = output.floatChannelData?[0] else { return }
                self.onAudioSamples?(
                    Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))),
                    self.outputFormat.sampleRate
                )
            } else if let channel = buffer.floatChannelData?[0] {
                self.onAudioSamples?(
                    Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))),
                    self.outputFormat.sampleRate
                )
            }
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            engine = audioEngine
            running = true
            onStateChange?(true)
            emit("SIRI REMOTE builtin fallback started sample_rate=\(format.sampleRate)")
        } catch {
            input.removeTap(onBus: 0)
            emit("SIRI REMOTE builtin fallback unavailable reason=start_failed error=\(error.localizedDescription)")
            onStateChange?(false)
        }
    }

    private func stopOnQueue() {
        guard running || engine != nil else { return }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil
        running = false
        onStateChange?(false)
        emit("SIRI REMOTE builtin fallback stopped")
    }

    private func emit(_ message: String) {
        AppLogger.shared.write(message)
        onDiagnostics?(message)
    }

    deinit { stop() }
}
