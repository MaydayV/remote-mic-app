import Testing
@testable import RemoteMic

@Suite("Compatibility driver management")
struct DoubaoDriverManagerTests {
    @Test func installationIsOnlyAllowedWhenAbsentAndSourceExists() {
        #expect(DoubaoDriverInstallPolicy.canInstall(state: .notInstalled, sourceAvailable: true))
        #expect(!DoubaoDriverInstallPolicy.canInstall(state: .notInstalled, sourceAvailable: false))
        #expect(!DoubaoDriverInstallPolicy.canInstall(state: .installed(version: "1"), sourceAvailable: true))
        #expect(!DoubaoDriverInstallPolicy.canInstall(state: .invalid, sourceAvailable: true))
    }

    @Test func uninstallOnlyTargetsARecognizedInstalledDriver() {
        #expect(DoubaoDriverInstallPolicy.canUninstall(state: .installed(version: nil)))
        #expect(!DoubaoDriverInstallPolicy.canUninstall(state: .notInstalled))
        #expect(!DoubaoDriverInstallPolicy.canUninstall(state: .invalid))
        #expect(DoubaoDriverInstallPolicy.bundleIdentifier == "com.hd838a.MiRemoteV2ch")
    }
}
