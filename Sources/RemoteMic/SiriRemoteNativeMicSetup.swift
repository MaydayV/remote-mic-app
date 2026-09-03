import Foundation

/// Performs the explicit administrator-authorized setup required by the native
/// Siri Remote capture path.  The app never writes the system preference
/// silently; macOS presents its normal administrator prompt for each change.
enum SiriRemoteNativeMicSetup {
    enum SetupError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Administrator authorization was cancelled."
            case .failed(let message):
                return message.isEmpty ? "The native Siri Remote capture setup failed." : message
            }
        }
    }

    static func setEnabled(
        _ enabled: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let command: String
            if enabled {
                command = """
                /usr/bin/defaults write /Library/Preferences/com.apple.MobileBluetooth.debug HCITraces -dict HCISkipAuth -bool true HCILiveTraces -bool true HCIFileTraces -bool true StackDebugEnabled -bool true RawAudioTrace -bool true HIDTrace -bool true
                /usr/bin/killall -30 bluetoothd
                """
            } else {
                command = """
                /usr/bin/defaults delete /Library/Preferences/com.apple.MobileBluetooth.debug HCITraces 2>/dev/null || true
                /usr/bin/killall -30 bluetoothd
                """
            }

            runAdministratorShell(command) { result in
                completion(result.map { _ in () })
            }
        }
    }

    /// Starts PacketLogger as root and returns its PID. HCI capture is one of
    /// the few PacketLogger operations that requires root on macOS. The process
    /// is detached from the short-lived authorization shell, so the app can
    /// continue tailing the capture file without blocking the UI.
    static func startPacketLogger(
        executableURL: URL,
        outputURL: URL,
        completion: @escaping (Result<Int32, Error>) -> Void
    ) {
        let command = "/usr/bin/nohup \(shellQuote(executableURL.path)) convert -o \(shellQuote(outputURL.path)) >/dev/null 2>&1 & echo $!"
        runAdministratorShell(command) { result in
            switch result {
            case .success(let output):
                guard let pid = Int32(output.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else {
                    completion(.failure(SetupError.failed("PacketLogger did not return a process ID.")))
                    return
                }
                completion(.success(pid))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    static func stopPacketLogger(pid: Int32, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard pid > 0 else {
            completion?(.success(()))
            return
        }
        let command = "if test \"$(/bin/ps -p \(pid) -o comm= 2>/dev/null | /usr/bin/sed 's#.*/##' | /usr/bin/tr -d '[:space:]')\" = packetlogger; then /bin/kill -TERM \(pid); fi"
        runAdministratorShell(command) { result in
            completion?(result.map { _ in () })
        }
    }

    /// Runs a fully quoted command after the normal
    /// macOS administrator prompt.  Settings uses this for reversible system
    /// audio driver operations as well as the native HCI capture setup.
    static func runPrivilegedCommand(
        _ command: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        runAdministratorShell(command, completion: completion)
    }

    private static func runAdministratorShell(
        _ command: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let message = String(
                data: output.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard process.terminationStatus == 0 else {
                let error: SetupError = message.localizedCaseInsensitiveContains("cancel")
                    ? .cancelled
                    : .failed(message)
                completion(.failure(error))
                return
            }
            completion(.success(message))
        } catch {
            completion(.failure(error))
        }
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
