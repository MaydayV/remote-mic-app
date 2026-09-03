import AppKit
import Foundation

/// Read-only state and explicit, reversible operations for the MiRemoteV 2ch
/// compatibility HAL driver.  The app never overwrites an installed bundle:
/// the user must uninstall it first, which keeps a failed update recoverable.
enum DoubaoDriverState: Equatable {
    case installed(version: String?)
    case notInstalled
    case invalid
}

enum DoubaoDriverInstallPolicy {
    static let bundleIdentifier = "com.hd838a.MiRemoteV2ch"
    static let destination = "/Library/Audio/Plug-Ins/HAL/MiRemoteV2ch.driver"

    static func canInstall(state: DoubaoDriverState, sourceAvailable: Bool) -> Bool {
        if case .notInstalled = state { return sourceAvailable }
        return false
    }

    static func canUninstall(state: DoubaoDriverState) -> Bool {
        if case .installed = state { return true }
        return false
    }
}

enum DoubaoDriverManager {
    static var destinationURL: URL {
        URL(fileURLWithPath: DoubaoDriverInstallPolicy.destination)
    }

    static func currentState() -> DoubaoDriverState {
        let destination = destinationURL
        let plist = destination.appendingPathComponent("Contents/Info.plist")
        guard FileManager.default.fileExists(atPath: destination.path) else {
            return .notInstalled
        }
        guard let values = NSDictionary(contentsOf: plist) as? [String: Any],
              values["CFBundleIdentifier"] as? String == DoubaoDriverInstallPolicy.bundleIdentifier
        else {
            return .invalid
        }
        return .installed(version: values["CFBundleVersion"] as? String)
    }

    /// The release app embeds the signed driver.  Development builds can use
    /// the build output or the installer staging directory, which keeps this
    /// feature testable without weakening the production package checks.
    static func sourceURL() -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("MiRemoteV2ch.driver"))
        }

        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        if executable.path.contains(".app/Contents/MacOS") {
            let appResources = executable
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/MiRemoteV2ch.driver")
            candidates.append(appResources)
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(contentsOf: [
            cwd.appendingPathComponent("dist/MiRemoteV2ch.driver"),
            cwd.appendingPathComponent("dist/intel/MiRemoteV2ch.driver"),
            URL(fileURLWithPath: "/Library/Application Support/RemoteMic/Installer/MiRemoteV2ch.driver")
        ])
        return candidates.first { isValidSource($0) }
    }

    static func install(completion: @escaping (Result<Void, Error>) -> Void) {
        let state = currentState()
        guard case .notInstalled = state else {
            completion(.failure(error("The compatibility driver is already installed. Uninstall it before installing a replacement.")))
            return
        }
        guard let source = sourceURL() else {
            completion(.failure(error("The signed MiRemoteV 2ch driver is not included in this app build.")))
            return
        }
        let sourcePath = SiriRemoteNativeMicSetup.shellQuote(source.path)
        let destinationPath = SiriRemoteNativeMicSetup.shellQuote(DoubaoDriverInstallPolicy.destination)
        let command = """
        test -d \(sourcePath)
        test ! -e \(destinationPath)
        /bin/mkdir -p '/Library/Audio/Plug-Ins/HAL'
        /usr/bin/ditto --norsrc --noextattr --noqtn --noacl \(sourcePath) \(destinationPath)
        /usr/sbin/chown -R root:wheel \(destinationPath)
        /usr/bin/find \(destinationPath) -type d -exec /bin/chmod 755 {} +
        /usr/bin/find \(destinationPath) -type f -exec /bin/chmod 644 {} +
        /bin/chmod 755 \(destinationPath)/Contents/MacOS/MiRemoteV2ch
        /usr/bin/codesign --verify --deep --strict \(destinationPath)
        /usr/bin/killall coreaudiod 2>/dev/null || true
        """
        SiriRemoteNativeMicSetup.runPrivilegedCommand(command) { result in
            completion(result.map { _ in () })
        }
    }

    static func uninstall(completion: @escaping (Result<Void, Error>) -> Void) {
        let destinationPath = SiriRemoteNativeMicSetup.shellQuote(DoubaoDriverInstallPolicy.destination)
        let command = """
        if test -e \(destinationPath); then
            test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \(destinationPath)/Contents/Info.plist 2>/dev/null || true)" = "\(DoubaoDriverInstallPolicy.bundleIdentifier)"
            /bin/rm -rf -- \(destinationPath)
            /usr/bin/killall coreaudiod 2>/dev/null || true
        fi
        """
        SiriRemoteNativeMicSetup.runPrivilegedCommand(command) { result in
            completion(result.map { _ in () })
        }
    }

    private static func isValidSource(_ url: URL) -> Bool {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        let binary = url.appendingPathComponent("Contents/MacOS/MiRemoteV2ch")
        guard FileManager.default.isExecutableFile(atPath: binary.path),
              let values = NSDictionary(contentsOf: plist) as? [String: Any]
        else { return false }
        return values["CFBundleIdentifier"] as? String == DoubaoDriverInstallPolicy.bundleIdentifier
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "RemoteMic.DoubaoDriverManager",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
