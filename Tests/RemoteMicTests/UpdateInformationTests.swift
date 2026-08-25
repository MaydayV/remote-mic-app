import Foundation
import Testing
@testable import RemoteMic

@Suite("Update information")
struct UpdateInformationTests {
    @Test func releaseFeedResolverUsesNewestPublishedMacAppcast() throws {
        let data = Data(#"""
        [
          {
            "draft": false,
            "published_at": "2026-08-10T04:26:12Z",
            "assets": [
              {
                "name": "appcast.xml",
                "browser_download_url": "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.3/appcast.xml"
              }
            ]
          },
          {
            "draft": true,
            "published_at": "2026-08-10T12:00:00Z",
            "assets": [
              {
                "name": "appcast.xml",
                "browser_download_url": "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.6/appcast.xml"
              }
            ]
          },
          {
            "draft": false,
            "published_at": "2026-08-10T10:00:20Z",
            "assets": [
              {
                "name": "Remote-Mic-1.8.5.zip",
                "browser_download_url": "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.5/Remote-Mic-1.8.5.zip"
              },
              {
                "name": "appcast.xml",
                "browser_download_url": "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.5/appcast.xml"
              }
            ]
          }
        ]
        """#.utf8)

        #expect(
            try UpdateFeedResolver.latestAppcastURL(from: data).absoluteString
                == "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.5/appcast.xml"
        )
    }

    @Test func releaseFeedResolverFailsClosedWhenNoAppcastExists() {
        let data = Data(#"""
        [
          {
            "draft": false,
            "published_at": "2026-08-10T10:00:20Z",
            "assets": []
          }
        ]
        """#.utf8)

        #expect(throws: UpdateFeedResolutionError.self) {
            try UpdateFeedResolver.latestAppcastURL(from: data)
        }
    }

    @Test func releaseFeedResolverKeepsIntelPreReleaseChecksOnTheIntelFeed() throws {
        let data = Data(#"""
        [
          {
            "draft": false,
            "published_at": "2026-08-12T01:00:00Z",
            "assets": [
              {
                "name": "appcast.xml",
                "browser_download_url": "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.11/appcast.xml"
              },
              {
                "name": "appcast-intel.xml",
                "browser_download_url": "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.11/appcast-intel.xml"
              }
            ]
          }
        ]
        """#.utf8)

        #expect(
            try UpdateFeedResolver.latestAppcastURL(
                from: data,
                assetName: "appcast-intel.xml"
            ).lastPathComponent == "appcast-intel.xml"
        )
    }

    @Test func localizedReleaseNotesUseImmutableReleaseAssetURLs() throws {
        let archiveURL = try #require(URL(
            string: "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.6/Remote-Mic-1.8.6.zip"
        ))

        #expect(
            UpdateReleaseNotes.assetURL(
                for: archiveURL,
                displayVersion: "1.8.6",
                localeIdentifier: "zh-Hans-CN"
            )?.absoluteString
                == "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.6/Remote-Mic-1.8.6.zh.txt"
        )
        #expect(
            UpdateReleaseNotes.assetURL(
                for: archiveURL,
                displayVersion: "1.8.6",
                localeIdentifier: "en-US"
            )?.absoluteString
                == "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.6/Remote-Mic-1.8.6.en.txt"
        )
        let appleSiliconArchiveURL = try #require(URL(
            string: "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.15/Remote-Mic-1.8.15-AppleSilicon.zip"
        ))
        #expect(
            UpdateReleaseNotes.assetURL(
                for: appleSiliconArchiveURL,
                displayVersion: "1.8.15",
                localeIdentifier: "zh-Hans"
            )?.lastPathComponent == "Remote-Mic-1.8.15-AppleSilicon.zh.txt"
        )
        #expect(UpdateReleaseNotes.assetURL(
            for: URL(string: "https://example.com/Remote-Mic-1.8.6.zip")!,
            displayVersion: "1.8.6",
            localeIdentifier: "en"
        ) == nil)
    }

    @Test func releaseNotesParserKeepsOnlyReadableContent() {
        #expect(UpdateReleaseNotes.parse("""
        # 1.8.6

        - First user-visible improvement
        • Second user-visible fix
        """) == [
            "First user-visible improvement",
            "Second user-visible fix",
        ])
    }

    @Test func releaseNotesParserSelectsTheCurrentLanguageSection() {
        let embeddedNotes = """
        中文更新内容
        - 修复中文更新说明

        What's New
        - English release note
        """

        #expect(UpdateReleaseNotes.parse(
            embeddedNotes,
            localeIdentifier: "zh-Hans"
        ) == ["修复中文更新说明"])
        #expect(UpdateReleaseNotes.parse(
            embeddedNotes,
            localeIdentifier: "en-US"
        ) == ["English release note"])
    }

    @Test func chineseReleaseNotesDoNotFallBackToEnglishText() {
        #expect(UpdateReleaseNotes.parse(
            "- 中文更新内容",
            localeIdentifier: "zh-Hans"
        ) == ["中文更新内容"])
        #expect(UpdateReleaseNotes.parse(
            "What's New\n- English-only release note",
            localeIdentifier: "zh-Hans"
        ).isEmpty)
    }

    @Test @MainActor func storeReloadsNotesForTheSelectedLanguage() async throws {
        let store = UpdateInformationStore { url in
            url.lastPathComponent.hasSuffix(".zh.txt")
                ? "- 中文更新内容"
                : "- English release note"
        }
        let archiveURL = try #require(URL(
            string: "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.6/Remote-Mic-1.8.6.zip"
        ))

        store.setAvailable(
            displayVersion: "1.8.6",
            buildVersion: "67",
            archiveURL: archiveURL,
            fallbackDescription: nil,
            localeIdentifier: "zh-Hans"
        )
        for _ in 0..<20 {
            if store.state == .available(AvailableUpdateInformation(
                displayVersion: "1.8.6",
                buildVersion: "67",
                releaseNotes: ["中文更新内容"]
            )) { break }
            await Task.yield()
        }
        #expect(store.state == .available(AvailableUpdateInformation(
            displayVersion: "1.8.6",
            buildVersion: "67",
            releaseNotes: ["中文更新内容"]
        )))

        store.reloadReleaseNotes(localeIdentifier: "en")
        for _ in 0..<20 {
            if store.state == .available(AvailableUpdateInformation(
                displayVersion: "1.8.6",
                buildVersion: "67",
                releaseNotes: ["English release note"]
            )) { break }
            await Task.yield()
        }
        #expect(store.state == .available(AvailableUpdateInformation(
            displayVersion: "1.8.6",
            buildVersion: "67",
            releaseNotes: ["English release note"]
        )))
    }

    @Test @MainActor func storeReloadsEmbeddedNotesForTheSelectedLanguage() throws {
        let store = UpdateInformationStore { _ in
            throw UpdateFeedResolutionError.invalidResponse
        }
        let archiveURL = try #require(URL(
            string: "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.15/Remote-Mic-1.8.15.zip"
        ))
        let embeddedNotes = """
        中文更新内容
        - 中文修复说明

        What's New
        - English fix description
        """

        store.setAvailable(
            displayVersion: "1.8.15",
            buildVersion: "100082",
            archiveURL: archiveURL,
            fallbackDescription: embeddedNotes,
            localeIdentifier: "zh-Hans"
        )
        #expect(store.state == .available(AvailableUpdateInformation(
            displayVersion: "1.8.15",
            buildVersion: "100082",
            releaseNotes: ["中文修复说明"]
        )))

        store.reloadReleaseNotes(localeIdentifier: "en-US")
        #expect(store.state == .available(AvailableUpdateInformation(
            displayVersion: "1.8.15",
            buildVersion: "100082",
            releaseNotes: ["English fix description"]
        )))
    }

    @Test @MainActor func storePrefersSparkleLocalizedReleaseNotesURL() async throws {
        let store = UpdateInformationStore { url in
            guard [
                "Remote-Mic-1.8.15-AppleSilicon.zh.txt",
                "Remote-Mic-1.8.15-AppleSilicon.en.txt",
            ].contains(url.lastPathComponent) else {
                throw UpdateFeedResolutionError.invalidResponse
            }
            return url.pathExtension == "txt" && url.lastPathComponent.hasSuffix(".en.txt")
                ? "- English localized note"
                : "- Sparkle localized note"
        }
        let archiveURL = try #require(URL(
            string: "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.15/Remote-Mic-1.8.15-AppleSilicon.zip"
        ))
        let releaseNotesURL = try #require(URL(
            string: "https://github.com/MaydayV/remote-mic-app/releases/download/v1.8.15/Remote-Mic-1.8.15-AppleSilicon.zh.txt"
        ))

        store.setAvailable(
            displayVersion: "1.8.15",
            buildVersion: "100082",
            archiveURL: archiveURL,
            releaseNotesURL: releaseNotesURL,
            fallbackDescription: nil,
            localeIdentifier: "zh-Hans"
        )
        for _ in 0..<20 {
            if store.state == .available(AvailableUpdateInformation(
                displayVersion: "1.8.15",
                buildVersion: "100082",
                releaseNotes: ["Sparkle localized note"]
            )) { break }
            await Task.yield()
        }
        #expect(store.state == .available(AvailableUpdateInformation(
            displayVersion: "1.8.15",
            buildVersion: "100082",
            releaseNotes: ["Sparkle localized note"]
        )))

        store.reloadReleaseNotes(localeIdentifier: "en-US")
        for _ in 0..<20 {
            if store.state == .available(AvailableUpdateInformation(
                displayVersion: "1.8.15",
                buildVersion: "100082",
                releaseNotes: ["English localized note"]
            )) { break }
            await Task.yield()
        }
        #expect(store.state == .available(AvailableUpdateInformation(
            displayVersion: "1.8.15",
            buildVersion: "100082",
            releaseNotes: ["English localized note"]
        )))
    }
}
