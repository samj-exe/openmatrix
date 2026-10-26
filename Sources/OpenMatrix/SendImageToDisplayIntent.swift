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
        try await IDotMatrixBluetooth.shared.sendImage(image.data)
        return .result(dialog: "Image sent to your iDotMatrix display.")
    }
}

@available(iOS 18.0, *)
struct OpenMatrixShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendImageToDisplayIntent(),
            phrases: ["Send an image to \(.applicationName)"],
            shortTitle: "Send to Display",
            systemImageName: "dot.radiowaves.left.and.right"
        )
    }
}
