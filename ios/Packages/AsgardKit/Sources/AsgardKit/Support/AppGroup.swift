import Foundation

/// Identifiers shared by the app and its extensions.
public enum AppGroup {
    public static let id = "group.com.giantmushroom.asgardchat"
    public static let keychainGroupSuffix = "com.giantmushroom.asgardchat.shared"

    public static var defaults: UserDefaults { UserDefaults(suiteName: id) ?? .standard }

    public static var containerURL: URL {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id)
            ?? URL.applicationSupportDirectory.appending(path: "AsgardShared")
    }

    public static var mediaCacheURL: URL {
        let url = containerURL.appending(path: "Media", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
