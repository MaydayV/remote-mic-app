import Combine
import Foundation

struct AvailableUpdateInformation: Equatable {
    let displayVersion: String
    let buildVersion: String
    let releaseNotes: [String]
}

enum UpdateInformationState: Equatable {
    case idle
    case checking
    case upToDate
    case unavailable
    case available(AvailableUpdateInformation)
}

enum UpdateFeedResolutionError: Error {
    case invalidResponse
    case feedNotFound
}

struct GitHubReleaseFeedRecord: Decodable, Equatable {
    struct Asset: Decodable, Equatable {
        let name: String
        let browserDownloadURL: URL

        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    let draft: Bool
    let publishedAt: String?
    let assets: [Asset]

    private enum CodingKeys: String, CodingKey {
        case draft
        case publishedAt = "published_at"
        case assets
    }
}

enum UpdateFeedResolver {
    static func latestAppcastURL(from data: Data, assetName: String = "appcast.xml") throws -> URL {
        let releases = try JSONDecoder().decode([GitHubReleaseFeedRecord].self, from: data)
        let orderedReleases = releases.enumerated().sorted { lhs, rhs in
            switch (lhs.element.publishedAt, rhs.element.publishedAt) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate > rhsDate
            default:
                return lhs.offset < rhs.offset
            }
        }
        guard let feedURL = orderedReleases.lazy
            .map(\.element)
            .filter({ !$0.draft })
            .flatMap(\.assets)
            .first(where: { $0.name == assetName })?
            .browserDownloadURL
        else {
            throw UpdateFeedResolutionError.feedNotFound
        }
        return feedURL
    }
}

enum UpdateReleaseNotes {
    private static let maximumDownloadSize = 128 * 1_024

    static func languageCode(for localeIdentifier: String) -> String {
        localeIdentifier.lowercased().hasPrefix("zh") ? "zh" : "en"
    }

    static func assetURL(
        for updateArchiveURL: URL,
        displayVersion: String,
        localeIdentifier: String
    ) -> URL? {
        guard updateArchiveURL.scheme == "https",
              updateArchiveURL.host == "github.com",
              displayVersion.range(of: #"^[0-9A-Za-z.-]+$"#, options: .regularExpression) != nil
        else { return nil }
        let languageCode = languageCode(for: localeIdentifier)
        return updateArchiveURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(updateArchiveURL.deletingPathExtension().lastPathComponent).\(languageCode).txt"
            )
    }

    static func parse(_ text: String, localeIdentifier: String? = nil) -> [String] {
        let lines = text.split(whereSeparator: \Character.isNewline)
        let selectedLines: ArraySlice<Substring>
        if let localeIdentifier,
           let section = localizedSection(in: lines, languageCode: languageCode(for: localeIdentifier)) {
            selectedLines = section
        } else {
            selectedLines = lines[...]
        }

        return selectedLines.compactMap { line in
            var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let isBullet = value.hasPrefix("- ") || value.hasPrefix("• ")
            if isBullet {
                value.removeFirst(2)
            }
            guard !value.isEmpty,
                  !value.hasPrefix("#"),
                  (isBullet || !isSectionHeading(value))
            else { return nil }
            return value
        }
    }

    private static func localizedSection(
        in lines: [Substring],
        languageCode: String
    ) -> ArraySlice<Substring>? {
        let headings = languageCode == "zh"
            ? ["中文更新内容", "更新内容"]
            : ["What's New", "What’s New"]
        guard let start = lines.firstIndex(where: { line in
            headings.contains(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }) else {
            // A legacy feed may contain only one language. Do not show English
            // text in the Chinese UI when a Chinese section is absent.
            let containsLanguageSections = lines.contains {
                isSectionHeading($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return languageCode == "zh" && containsLanguageSections ? [] : nil
        }
        let end = lines[(start + 1)...].firstIndex(where: { line in
            isSectionHeading(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }) ?? lines.endIndex
        return lines[start..<end]
    }

    private static func isSectionHeading(_ value: String) -> Bool {
        ["中文更新内容", "更新内容", "What's New", "What’s New"].contains(value)
    }

    static func load(from url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        request.setValue("RemoteMic", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              data.count <= maximumDownloadSize,
              let text = String(data: data, encoding: .utf8)
        else {
            throw UpdateFeedResolutionError.invalidResponse
        }
        return text
    }
}

@MainActor
final class UpdateInformationStore: ObservableObject {
    typealias NotesLoader = @Sendable (URL) async throws -> String

    @Published private(set) var state: UpdateInformationState = .idle

    private struct PendingUpdate: Equatable {
        let displayVersion: String
        let buildVersion: String
        let archiveURL: URL?
        let releaseNotesURL: URL?
        let fallbackDescription: String?
    }

    private let notesLoader: NotesLoader
    private var pendingUpdate: PendingUpdate?
    private var notesTask: Task<Void, Never>?
    private var notesGeneration = 0

    init(
        notesLoader: @escaping NotesLoader = { url in
            try await UpdateReleaseNotes.load(from: url)
        }
    ) {
        self.notesLoader = notesLoader
    }

    deinit {
        notesTask?.cancel()
    }

    func beginChecking() {
        state = .checking
    }

    func reset() {
        notesTask?.cancel()
        pendingUpdate = nil
        state = .idle
    }

    func setUpToDate() {
        notesTask?.cancel()
        pendingUpdate = nil
        state = .upToDate
    }

    func setUnavailable() {
        notesTask?.cancel()
        pendingUpdate = nil
        state = .unavailable
    }

    func setAvailable(
        displayVersion: String,
        buildVersion: String,
        archiveURL: URL?,
        releaseNotesURL: URL? = nil,
        fallbackDescription: String?,
        localeIdentifier: String
    ) {
        let pending = PendingUpdate(
            displayVersion: displayVersion,
            buildVersion: buildVersion,
            archiveURL: archiveURL,
            releaseNotesURL: releaseNotesURL,
            fallbackDescription: fallbackDescription
        )
        pendingUpdate = pending
        state = .available(information(
            for: pending,
            notes: UpdateReleaseNotes.parse(
                fallbackDescription ?? "",
                localeIdentifier: localeIdentifier
            )
        ))
        loadReleaseNotes(
            for: pending,
            localeIdentifier: localeIdentifier,
            preferProvidedReleaseNotesURL: true
        )
    }

    func reloadReleaseNotes(localeIdentifier: String) {
        guard let pendingUpdate else { return }
        state = .available(information(
            for: pendingUpdate,
            notes: UpdateReleaseNotes.parse(
                pendingUpdate.fallbackDescription ?? "",
                localeIdentifier: localeIdentifier
            )
        ))
        loadReleaseNotes(
            for: pendingUpdate,
            localeIdentifier: localeIdentifier,
            preferProvidedReleaseNotesURL: false
        )
    }

    private func information(
        for pending: PendingUpdate,
        notes: [String]
    ) -> AvailableUpdateInformation {
        AvailableUpdateInformation(
            displayVersion: pending.displayVersion,
            buildVersion: pending.buildVersion,
            releaseNotes: notes
        )
    }

    private func loadReleaseNotes(
        for pending: PendingUpdate,
        localeIdentifier: String,
        preferProvidedReleaseNotesURL: Bool
    ) {
        notesTask?.cancel()
        let notesURL = (preferProvidedReleaseNotesURL ? pending.releaseNotesURL : nil) ??
            pending.archiveURL.flatMap {
            UpdateReleaseNotes.assetURL(
                for: $0,
                displayVersion: pending.displayVersion,
                localeIdentifier: localeIdentifier
            )
        }
        guard let notesURL
        else { return }

        notesGeneration += 1
        let generation = notesGeneration
        let notesLoader = notesLoader
        notesTask = Task { [weak self] in
            do {
                let text = try await notesLoader(notesURL)
                guard !Task.isCancelled, let self,
                      generation == self.notesGeneration,
                      self.pendingUpdate == pending
                else { return }
                let notes = UpdateReleaseNotes.parse(text, localeIdentifier: localeIdentifier)
                guard !notes.isEmpty else { return }
                self.state = .available(self.information(for: pending, notes: notes))
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }
}
