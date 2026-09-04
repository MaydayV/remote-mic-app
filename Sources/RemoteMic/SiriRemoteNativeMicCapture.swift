//
//  SiriRemoteNativeMicCapture.swift
//  RemoteMic
//
//  Native macOS microphone path for Siri Remote.
//
//  macOS owns the remote's HOGP connection, so IOHID cannot address the
//  microphone GATT characteristic directly.  PacketLogger can observe the
//  HCI traffic instead.  This component tails PacketLogger's lossless binary
//  capture, reassembles ACL/L2CAP packets, extracts the ATT voice notification,
//  and reuses the app's existing Opus decoder and virtual audio output.
//
//  The required HCI trace debug preference is changed only through the explicit
//  Settings action (or scripts/enable-siri-remote-native-mic.sh).  Enabling it
//  changes system Bluetooth behaviour and requires administrator approval.
//

import Darwin
import Foundation

struct SiriRemoteNativeMicAvailability: Equatable {
    let packetLoggerAvailable: Bool
    let traceConfigured: Bool

    var ready: Bool {
        packetLoggerAvailable && traceConfigured
    }
}

/// A decoded voice frame from the Siri Remote's ATT notification stream.
struct SiriRemoteNativeVoiceFrame {
    let connectionHandle: String
    let attributeHandle: UInt16
    let sequence: UInt16
    let opusPayload: Data
}

/// Parses the binary/ASCII framing emitted by Apple's PacketLogger tools.
enum SiriRemoteNativeVoiceFrameParser {
    private static let notificationSignature: [UInt8] = [0x04, 0x00, 0x1B]

    /// Extract a voice frame from a reassembled L2CAP PDU or an nhdr byte line.
    ///
    /// The ATT value is `[4-byte sequence/header][opus-length][opus]`.  The
    /// first two bytes are transport metadata; bytes 2…3 are the per-hold
    /// sequence number.  The value's first Opus byte is `0xB8` for the
    /// third-generation remote's CELT wideband stream.
    static func parse(bytes: [UInt8], connectionHandle: String) -> SiriRemoteNativeVoiceFrame? {
        guard let signatureIndex = firstIndex(of: notificationSignature, in: bytes),
              signatureIndex + notificationSignature.count + 2 <= bytes.count
        else { return nil }

        let attributeIndex = signatureIndex + notificationSignature.count
        let attributeHandle = UInt16(bytes[attributeIndex])
            | (UInt16(bytes[attributeIndex + 1]) << 8)
        let valueIndex = attributeIndex + 2
        guard valueIndex + 5 <= bytes.count else { return nil }

        let sequence = UInt16(bytes[valueIndex + 2])
            | (UInt16(bytes[valueIndex + 3]) << 8)
        let opusLength = Int(bytes[valueIndex + 4])
        let opusIndex = valueIndex + 5
        guard opusLength >= 2, opusIndex + opusLength <= bytes.count else { return nil }

        let payload = Array(bytes[opusIndex..<(opusIndex + opusLength)])
        guard payload.first == 0xB8 else { return nil }
        return SiriRemoteNativeVoiceFrame(
            connectionHandle: connectionHandle,
            attributeHandle: attributeHandle,
            sequence: sequence,
            opusPayload: Data(payload)
        )
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) {
                return start
            }
        }
        return nil
    }
}

/// Incrementally reassembles PacketLogger `.pklg` ACL records into ATT PDUs.
///
/// PacketLogger writes a big-endian record length followed by seconds,
/// microseconds, record type and payload.  A voice notification normally spans
/// more than one ACL fragment, so parsing individual records would lose frames.
final class SiriRemotePacketLoggerVoiceExtractor {
    private var residual = [UInt8]()
    private var assembling: [Int: (l2capLength: Int, buffer: [UInt8])] = [:]

    private(set) var recordsScanned = 0
    private(set) var aclFragmentsScanned = 0

    func ingest(_ data: Data) -> [SiriRemoteNativeVoiceFrame] {
        if !data.isEmpty { residual.append(contentsOf: data) }
        var frames: [SiriRemoteNativeVoiceFrame] = []
        var offset = 0

        while offset + 4 <= residual.count {
            let length = Int(residual[offset]) << 24
                | Int(residual[offset + 1]) << 16
                | Int(residual[offset + 2]) << 8
                | Int(residual[offset + 3])
            guard length >= 9 else { break }
            let recordEnd = offset + 4 + length
            guard recordEnd <= residual.count else { break }

            let type = residual[offset + 12]
            if type == 0x03 { // HCI ACL data received
                let payload = Array(residual[(offset + 13)..<recordEnd])
                aclFragmentsScanned += 1
                if let frame = handleACL(payload) { frames.append(frame) }
            }
            recordsScanned += 1
            offset = recordEnd
        }

        if offset > 0 { residual.removeFirst(offset) }
        return frames
    }

    private func handleACL(_ payload: [UInt8]) -> SiriRemoteNativeVoiceFrame? {
        guard payload.count >= 4 else { return nil }
        let header = Int(payload[0]) | (Int(payload[1]) << 8)
        let connectionHandle = header & 0x0FFF
        let packetBoundary = (header >> 12) & 0x3
        let aclLength = Int(payload[2]) | (Int(payload[3]) << 8)
        let dataEnd = min(4 + aclLength, payload.count)
        guard dataEnd > 4 else { return nil }
        let aclData = payload[4..<dataEnd]

        if packetBoundary == 0x2 || packetBoundary == 0x0 {
            guard aclData.count >= 2 else {
                assembling[connectionHandle] = nil
                return nil
            }
            let l2capLength = Int(aclData[aclData.startIndex])
                | (Int(aclData[aclData.startIndex + 1]) << 8)
            assembling[connectionHandle] = (l2capLength, Array(aclData))
        } else if packetBoundary == 0x1 {
            guard assembling[connectionHandle] != nil else { return nil }
            assembling[connectionHandle]!.buffer.append(contentsOf: aclData)
        } else {
            return nil
        }

        guard let state = assembling[connectionHandle],
              state.buffer.count >= 4 + state.l2capLength
        else { return nil }
        assembling[connectionHandle] = nil

        return SiriRemoteNativeVoiceFrameParser.parse(
            bytes: state.buffer,
            connectionHandle: String(format: "0x%04X", connectionHandle)
        )
    }
}

/// Small bounded jitter buffer for BLE voice bursts.  PacketLogger delivers
/// several ACL notifications together, while AVAudioEngine consumes at a steady
/// clock.  Three frames (60 ms) absorb normal scheduling jitter without adding
/// noticeable push-to-talk latency.
final class SiriRemoteNativeJitterBuffer {
    private var samples = [Float]()
    private var primed = false
    private let primeSampleCount = 3 * 960
    private let maxSampleCount = 48_000

    func reset() {
        samples.removeAll(keepingCapacity: true)
        primed = false
    }

    func append(_ frame: [Float]) -> [[Float]] {
        guard !frame.isEmpty else { return [] }
        samples.append(contentsOf: frame)
        if samples.count > maxSampleCount {
            samples.removeFirst(samples.count - maxSampleCount)
        }
        guard primed else {
            guard samples.count >= primeSampleCount else { return [] }
            primed = true
            let output = samples
            samples.removeAll(keepingCapacity: true)
            return [output]
        }
        let output = samples
        samples.removeAll(keepingCapacity: true)
        return [output]
    }
}

/// Captures and decodes Siri Remote voice traffic using native macOS tools.
///
/// This class deliberately does not alter Bluetooth debug preferences.  The
/// capture process is started only when the Siri backend is active, and is
/// stopped when that backend is stopped.  If PacketLogger or the trace setup
/// is unavailable, the existing direct-HID path remains available as a
/// best-effort fallback.
final class SiriRemoteNativeMicCapture {
    typealias AudioHandler = ([Float], Double) -> Void

    var onAudioSamples: AudioHandler?
    var onDiagnostics: ((String) -> Void)?
    var onCaptureStateChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(
        label: "RemoteMic.siri-native-mic-capture",
        qos: .userInitiated
    )
    private var packetLoggerPID: Int32?
    private var pollTimer: DispatchSourceTimer?
    private var captureURL: URL?
    private var readOffset: UInt64 = 0
    private var extractor = SiriRemotePacketLoggerVoiceExtractor()
    private var decoder: OpusDecoder?
    private let jitterBuffer = SiriRemoteNativeJitterBuffer()
    private var started = false
    private var voiceActive = false
    private var previousSequence: UInt16?
    private var voiceFrames = 0
    private var decodedFrames = 0
    private var decodeErrors = 0

    /// Start PacketLogger capture. Safe to call repeatedly.
    func start() {
        queue.async { [weak self] in
            self?.startOnQueue()
        }
    }

    /// Stop capture and terminate the PacketLogger process.
    func stop() {
        queue.async { [weak self] in
            self?.stopOnQueue()
        }
    }

    func startVoice() {
        queue.async { [weak self] in
            guard let self else { return }
            self.voiceActive = true
            self.previousSequence = nil
            self.jitterBuffer.reset()
            if !self.started { self.startOnQueue() }
        }
    }

    func stopVoice() {
        queue.async { [weak self] in
            self?.voiceActive = false
            self?.previousSequence = nil
            self?.jitterBuffer.reset()
        }
    }

    private func startOnQueue() {
        guard !started else { return }
        guard let packetLogger = Self.packetLoggerURL() else {
            onCaptureStateChange?(false)
            emit("SIRI REMOTE native mic unavailable reason=packetlogger_not_found")
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteMic", isDirectory: true)
            .appendingPathComponent("SiriRemoteCapture", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent("capture-\(UUID().uuidString).pklg")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw NSError(
                    domain: "RemoteMic.SiriRemoteNativeMicCapture",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Unable to create PacketLogger capture file."]
                )
            }
            captureURL = url
            readOffset = 0
            extractor = SiriRemotePacketLoggerVoiceExtractor()
            decoder = try? OpusDecoder()
            SiriRemoteNativeMicSetup.startPacketLogger(executableURL: packetLogger, outputURL: url) {
                [weak self] result in
                self?.queue.async {
                    guard let self else { return }
                    switch result {
                    case .success(let pid):
                        self.packetLoggerPID = pid
                        self.started = true
                        self.onCaptureStateChange?(true)
                        let timer = DispatchSource.makeTimerSource(queue: self.queue)
                        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(5))
                        timer.setEventHandler { [weak self] in self?.drainCaptureFile() }
                        timer.resume()
                        self.pollTimer = timer
                        let traceState = Self.hciTraceConfigurationPresent() ? "configured" : "not_configured"
                        self.emit("SIRI REMOTE native mic capture started packetlogger=\(packetLogger.path) pid=\(pid) trace=\(traceState)")
                        if traceState == "not_configured" {
                            self.emit("SIRI REMOTE native mic setup required action=run_enable_script")
                        }
                    case .failure(let error):
                        self.onCaptureStateChange?(false)
                        self.emit("SIRI REMOTE native mic unavailable reason=packetlogger_start_failed error=\(error.localizedDescription)")
                        self.stopOnQueue()
                    }
                }
            }
        } catch {
            emit("SIRI REMOTE native mic unavailable reason=packetlogger_start_failed error=\(error.localizedDescription)")
            stopOnQueue()
        }
    }

    private func stopOnQueue() {
        pollTimer?.setEventHandler {}
        pollTimer?.cancel()
        pollTimer = nil
        onCaptureStateChange?(false)
        if let packetLoggerPID {
            SiriRemoteNativeMicSetup.stopPacketLogger(pid: packetLoggerPID)
        }
        packetLoggerPID = nil
        if let url = captureURL {
            try? FileManager.default.removeItem(at: url)
        }
        captureURL = nil
        readOffset = 0
        started = false
        voiceActive = false
        previousSequence = nil
        jitterBuffer.reset()
        decoder = nil
        emit("SIRI REMOTE native mic capture stopped frames=\(voiceFrames) decoded=\(decodedFrames) errors=\(decodeErrors)")
        voiceFrames = 0
        decodedFrames = 0
        decodeErrors = 0
    }

    private func drainCaptureFile() {
        guard let url = captureURL,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: readOffset)
            let data = try handle.readToEnd() ?? Data()
            readOffset += UInt64(data.count)
            guard !data.isEmpty else { return }

            for frame in extractor.ingest(data) {
                voiceFrames += 1
                guard voiceActive else { continue }
                if let previousSequence {
                    let distance = Int(frame.sequence &- previousSequence)
                    if distance == 0 { continue }
                    if distance > 1 && distance <= 10 {
                        // Preserve the remote's timeline when one or more BLE
                        // notifications were dropped before PacketLogger saw them.
                        for _ in 1..<distance {
                            publish(Array(repeating: 0, count: 960))
                        }
                    } else if distance > 10 {
                        // A new Siri hold normally restarts at zero. Avoid
                        // synthesizing a large stale gap across holds.
                        jitterBuffer.reset()
                    }
                }
                self.previousSequence = frame.sequence
                guard let decoder,
                      let samples = try? decoder.decode(frame.opusPayload),
                      !samples.isEmpty
                else {
                    decodeErrors += 1
                    continue
                }
                decodedFrames += 1
                publish(samples)
            }
        } catch {
            emit("SIRI REMOTE native mic read failed error=\(error.localizedDescription)")
        }

        if let packetLoggerPID {
            if kill(packetLoggerPID, 0) != 0, errno == ESRCH {
                emit("SIRI REMOTE native mic process exited pid=\(packetLoggerPID)")
                stopOnQueue()
            }
        }
    }

    private func publish(_ samples: [Float]) {
        let callback = onAudioSamples
        for output in jitterBuffer.append(samples) {
            DispatchQueue.main.async {
                callback?(output, 48_000)
            }
        }
    }

    private func emit(_ message: String) {
        AppLogger.shared.write(message)
        onDiagnostics?(message)
    }

    /// Locate Apple's PacketLogger binary from Additional Tools or a PATH install.
    static func packetLoggerURL() -> URL? {
        let fileManager = FileManager.default
        let packetLoggerRelativePath = [
            "PacketLogger.app/Contents/Resources/packetlogger"
        ]
        var candidates = [
            "/Applications/PacketLogger.app/Contents/Resources/packetlogger",
            "/Applications/Additional Tools/PacketLogger.app/Contents/Resources/packetlogger",
            "/Applications/Additional Tools for Xcode/PacketLogger.app/Contents/Resources/packetlogger",
            "/Volumes/Additional Tools/Hardware/PacketLogger.app/Contents/Resources/packetlogger",
        ]
        let home = fileManager.homeDirectoryForCurrentUser
        for root in [
            home.appendingPathComponent("Applications"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop")
        ] {
            candidates += packetLoggerRelativePath.map {
                root.appendingPathComponent($0).path
            }
            for name in ["Additional Tools", "Additional Tools for Xcode"] {
                let toolsRoot = root.appendingPathComponent(name)
                candidates.append(
                    toolsRoot
                        .appendingPathComponent("Hardware/PacketLogger.app/Contents/Resources/packetlogger")
                        .path
                )
                candidates.append(
                    toolsRoot
                        .appendingPathComponent("PacketLogger.app/Contents/Resources/packetlogger")
                        .path
                )
            }
        }
        if let path = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let which = Process()
        let output = Pipe()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["packetlogger"]
        which.standardOutput = output
        which.standardError = FileHandle.nullDevice
        do {
            try which.run()
            which.waitUntilExit()
            guard which.terminationStatus == 0 else { return nil }
            let path = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, fileManager.isExecutableFile(atPath: path) else { return nil }
            return URL(fileURLWithPath: path)
        } catch {
            return nil
        }
    }

    /// Returns whether the opt-in HCI trace dictionary is present.  We only
    /// inspect the preference; enabling it remains an explicit script action.
    static func hciTraceConfigurationPresent() -> Bool {
        let read = Process()
        let output = Pipe()
        read.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        read.arguments = [
            "read",
            "/Library/Preferences/com.apple.MobileBluetooth.debug",
            "HCITraces",
        ]
        read.standardOutput = output
        read.standardError = FileHandle.nullDevice
        do {
            try read.run()
            read.waitUntilExit()
            guard read.terminationStatus == 0 else { return false }
            let text = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            return text.contains("RawAudioTrace")
        } catch {
            return false
        }
    }

    static func availability() -> SiriRemoteNativeMicAvailability {
        SiriRemoteNativeMicAvailability(
            packetLoggerAvailable: packetLoggerURL() != nil,
            traceConfigured: hciTraceConfigurationPresent()
        )
    }
}
