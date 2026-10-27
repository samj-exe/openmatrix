import AppIntents
import Foundation

@available(iOS 18.0, *)
struct SendImageToDisplayIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Image to Display"
    static let description = IntentDescription("Send an image to your selected iDotMatrix display.")
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Image")
    var image: IntentFile

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$image) to my display")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let acknowledged = try await IDotMatrixBluetooth.shared.sendImage(image.data)
        if acknowledged {
            return .result(dialog: "Bluetooth acknowledged the transfer. The display does not confirm image rendering.")
        }
        return .result(dialog: "Image transfer sent. A Bluetooth write acknowledgement was not available.")
    }
}

@available(iOS 18.0, *)
struct SyncNowPlayingCoverArtIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Now Playing Cover Art"
    static let description = IntentDescription("Send the cover art for your Last.fm now-playing track to your selected display.")
    static let openAppWhenRun = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        _ = try await LastFMService.shared.syncCurrentTrack()
        return .result(dialog: "Last.fm was checked for a now-playing track. Check OpenMatrix for transfer status.")
    }
}

@available(iOS 18.0, *)
struct OpenMatrixShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        [
            AppShortcut(
                intent: SendImageToDisplayIntent(),
                phrases: ["Send an image to \(.applicationName)"],
                shortTitle: "Send to Display",
                systemImageName: "dot.radiowaves.left.and.right"
            ),
            AppShortcut(
                intent: SyncNowPlayingCoverArtIntent(),
                phrases: ["Sync now playing cover art with \(.applicationName)"],
                shortTitle: "Sync Now Playing",
                systemImageName: "music.note"
            )
        ]
    }
}
