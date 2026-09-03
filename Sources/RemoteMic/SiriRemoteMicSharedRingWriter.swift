import Darwin
import Foundation

// Swift 6 marks variadic C declarations unavailable. Bind the fixed three
// argument POSIX form explicitly; macOS implements this symbol in libSystem.
@_silgen_name("shm_open")
private func srm_shm_open(
    _ name: UnsafePointer<CChar>,
    _ oflag: Int32,
    _ mode: mode_t
) -> Int32

/// The shared-memory ABI used by the optional system-wide Siri Remote Mic HAL.
///
/// The app remains fully functional without the HAL: VirtualAudioOutput is
/// still the primary route. When the HAL is installed, these rings let its
/// realtime ReadInput callback consume the same remote and built-in fallback
/// samples without another audio conversion or IPC layer.
final class SiriRemoteMicSharedRingWriter {
    private static let remoteName = "/SiriRemoteMicAudio"
    private static let builtinName = "/SiriRemoteMicBuiltin"
    private static let magic: UInt32 = 0x53524D31 // SRM1
    private static let version: UInt32 = 1
    private static let sampleRate: UInt32 = 48_000
    private static let ringFrames = 65_536
    // C11 _Atomic<uint64_t> is 8-byte aligned after the 24-byte prefix, so the
    // ring starts at offset 40 (not 32) on both arm64 and x86_64.
    private static let ringOffset = 40
    private static let mappingSize = ringOffset + ringFrames * MemoryLayout<Float>.size

    private struct Region {
        let descriptor: Int32
        let mapping: UnsafeMutableRawPointer
        var writeIndex: UInt64
    }

    private let lock = NSLock()
    private var remote: Region?
    private var builtin: Region?

    func start() {
        lock.lock()
        defer { lock.unlock() }
        if remote == nil { remote = openRegion(Self.remoteName) }
        if builtin == nil { builtin = openRegion(Self.builtinName) }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        setActiveLocked(&remote, active: false)
        setActiveLocked(&builtin, active: false)
        closeRegion(&remote)
        closeRegion(&builtin)
    }

    func setRemoteActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        setActiveLocked(&remote, active: active)
    }

    func setBuiltinActive(_ active: Bool) {
        lock.lock(); defer { lock.unlock() }
        setActiveLocked(&builtin, active: active)
    }

    func writeRemote(_ samples: [Float]) {
        write(samples, to: .remote)
    }

    func writeBuiltin(_ samples: [Float]) {
        write(samples, to: .builtin)
    }

    private enum Destination { case remote, builtin }

    private func write(_ samples: [Float], to destination: Destination) {
        guard !samples.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        switch destination {
        case .remote:
            writeLocked(samples, region: &remote)
        case .builtin:
            writeLocked(samples, region: &builtin)
        }
    }

    private func writeLocked(_ samples: [Float], region: inout Region?) {
        guard region != nil else { return }
        let ring = region!.mapping.advanced(by: Self.ringOffset).assumingMemoryBound(to: Float.self)
        for sample in samples {
            ring[Int(region!.writeIndex % UInt64(Self.ringFrames))] = sample
            region!.writeIndex &+= 1
        }
        // The aligned scalar store is atomic on the supported architectures;
        // the compiler barrier keeps sample writes before the published index.
        OSMemoryBarrier()
        let index = region!.writeIndex
        region!.mapping.advanced(by: 32).assumingMemoryBound(to: UInt64.self).pointee = index
    }

    private func openRegion(_ name: String) -> Region? {
        let descriptor = name.withCString {
            srm_shm_open($0, O_CREAT | O_RDWR, mode_t(0o666))
        }
        guard descriptor >= 0 else {
            AppLogger.shared.write("SIRI REMOTE shared ring unavailable name=\(name) error=\(errno)")
            return nil
        }
        guard ftruncate(descriptor, off_t(Self.mappingSize)) == 0 else {
            close(descriptor)
            return nil
        }
        let mapping = mmap(
            nil,
            Self.mappingSize,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            descriptor,
            0
        )
        guard mapping != MAP_FAILED else {
            close(descriptor)
            return nil
        }
        let raw = mapping!
        raw.storeBytes(of: Self.magic, as: UInt32.self)
        raw.advanced(by: 4).storeBytes(of: Self.version, as: UInt32.self)
        raw.advanced(by: 8).storeBytes(of: Self.sampleRate, as: UInt32.self)
        raw.advanced(by: 12).storeBytes(of: UInt32(1), as: UInt32.self)
        raw.advanced(by: 16).storeBytes(of: UInt32(Self.ringFrames), as: UInt32.self)
        raw.advanced(by: 20).storeBytes(of: UInt32(0), as: UInt32.self)
        raw.advanced(by: 24).storeBytes(of: UInt32(0), as: UInt32.self)
        raw.advanced(by: 32).storeBytes(of: UInt64(0), as: UInt64.self)
        memset(raw.advanced(by: Self.ringOffset), 0, Self.ringFrames * MemoryLayout<Float>.size)
        return Region(descriptor: descriptor, mapping: raw, writeIndex: 0)
    }

    private func setActiveLocked(_ region: inout Region?, active: Bool) {
        OSMemoryBarrier()
        region?.mapping.advanced(by: 24).storeBytes(of: UInt32(active ? 1 : 0), as: UInt32.self)
    }

    private func closeRegion(_ region: inout Region?) {
        guard let value = region else { return }
        value.mapping.advanced(by: 24).storeBytes(of: UInt32(0), as: UInt32.self)
        munmap(value.mapping, Self.mappingSize)
        close(value.descriptor)
        region = nil
    }

    deinit { stop() }
}
