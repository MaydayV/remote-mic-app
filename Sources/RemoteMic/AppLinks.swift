import Foundation

enum AppLinks {
    static let githubRepository = URL(
        string: "https://github.com/MaydayV/remote-mic-app"
    )!
    static let chineseWebsite = URL(string: "https://8586ai.com/")!
    static let englishWebsite = URL(string: "https://8586ai.com/en/")!
    static func website(for locale: Locale) -> URL {
        locale.identifier.lowercased().hasPrefix("zh")
            ? chineseWebsite
            : englishWebsite
    }
}
