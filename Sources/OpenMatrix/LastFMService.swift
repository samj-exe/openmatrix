import BackgroundTasks
import Combine
import Foundation

@MainActor
final class LastFMService: ObservableObject {
    static let shared = LastFMService()
    static let backgroundTaskIdentifier = "com.openmatrix.app.lastfm-refresh"

    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "lastFMAPIKey") }
    }
    @Published var username: String {
        didSet { UserDefaults.standard.set(username, forKey: "lastFMUsername") }
    }
    @Published private(set) var status = "Add your Last.fm API key and username to enable cover sync."
    @Published private(set) var isSyncing = false

    private let defaults = UserDefaults.standard
    var isConfigured: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private init() {
        apiKey = UserDefaults.standard.string(forKey: "lastFMAPIKey") ?? ""
        username = UserDefaults.standard.string(forKey: "lastFMUsername") ?? ""
    }

    @discardableResult
    func syncCurrentTrack(force: Bool = true) async throws -> String {
        guard !isSyncing else { throw LastFMError.syncInProgress }
        isSyncing = true
        defer { isSyncing = false }

        do {
            let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !user.isEmpty else { throw LastFMError.missingCredentials }
            guard IDotMatrixBluetooth.shared.selectedDisplayName != nil else {
                throw LastFMError.displayNotSelected
            }

            var components = URLComponents(string: "https://ws.audioscrobbler.com/2.0/")
            components?.queryItems = [
                URLQueryItem(name: "method", value: "user.getrecenttracks"),
                URLQueryItem(name: "user", value: user),
                URLQueryItem(name: "api_key", value: key),
                URLQueryItem(name: "limit", value: "1"),
                URLQueryItem(name: "format", value: "json")
            ]
            guard let url = components?.url else { throw LastFMError.invalidRequest }

            let (responseData, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw LastFMError.serverResponse
            }
            guard let root = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
                throw LastFMError.invalidResponse
            }
            if let apiError = root["message"] as? String {
                throw LastFMError.api(apiError)
            }
            guard let recentTracks = root["recenttracks"] as? [String: Any],
                  let track = Self.firstTrack(from: recentTracks["track"]) else {
                throw LastFMError.invalidResponse
            }
            let attributes = track["@attr"] as? [String: Any]
            guard attributes?["nowplaying"] as? String == "true" else {
                status = "Last.fm does not currently report a now-playing track for \(user)."
                return status
            }

            let artist = Self.text(in: track["artist"])
            let title = track["name"] as? String ?? "Unknown track"
            let trackKey = "\(user.lowercased())|\(artist.lowercased())|\(title.lowercased())"
            let storedKey = defaults.string(forKey: "lastFMSyncedTrack")
            if !force, storedKey == trackKey {
                status = "Now playing: \(artist) — \(title). Cover art is already synced."
                return status
            }

            guard let artworkString = Self.artworkURL(in: track["image"]),
                  let artworkURL = URL(string: artworkString),
                  artworkURL.scheme == "https" else {
                throw LastFMError.artworkUnavailable
            }
            let (artworkData, artworkResponse) = try await URLSession.shared.data(from: artworkURL)
            guard let artworkHTTPResponse = artworkResponse as? HTTPURLResponse,
                  (200..<300).contains(artworkHTTPResponse.statusCode),
                  !artworkData.isEmpty else {
                throw LastFMError.artworkUnavailable
            }

            try Task.checkCancellation()
            let acknowledged = try await IDotMatrixBluetooth.shared.sendImage(artworkData)
            defaults.set(trackKey, forKey: "lastFMSyncedTrack")
            status = acknowledged
                ? "Synced cover art for \(artist) — \(title). Bluetooth acknowledged the transfer."
                : "Synced cover art for \(artist) — \(title). No Bluetooth write acknowledgement was available."
            return status
        } catch {
            if !(error is CancellationError) {
                status = error.localizedDescription
            }
            throw error
        }
    }

    func syncIfTrackChanged() async {
        guard !isSyncing,
              !IDotMatrixBluetooth.shared.isSending,
              !IDotMatrixBluetooth.shared.isScanning,
              isConfigured else { return }
        guard IDotMatrixBluetooth.shared.selectedDisplayName != nil else {
            status = "Select a display before syncing Last.fm cover art."
            return
        }
        do {
            _ = try await syncCurrentTrack(force: false)
        } catch is CancellationError {
            return
        } catch {
            status = error.localizedDescription
        }
    }

    private static func firstTrack(from value: Any?) -> [String: Any]? {
        if let tracks = value as? [[String: Any]] {
            return tracks.first
        }
        return value as? [String: Any]
    }

    private static func text(in value: Any?) -> String {
        if let object = value as? [String: Any] {
            return object["#text"] as? String ?? object["name"] as? String ?? "Unknown artist"
        }
        return value as? String ?? "Unknown artist"
    }

    private static func artworkURL(in value: Any?) -> String? {
        guard let images = value as? [[String: Any]] else { return nil }
        return images.reversed().compactMap { $0["#text"] as? String }
            .first { !$0.isEmpty }
    }

    private enum LastFMError: LocalizedError {
        case missingCredentials
        case displayNotSelected
        case invalidRequest
        case serverResponse
        case invalidResponse
        case artworkUnavailable
        case syncInProgress
        case api(String)

        var errorDescription: String? {
            switch self {
            case .missingCredentials:
                return "Enter your Last.fm API key and username before syncing."
            case .displayNotSelected:
                return "Select your iDotMatrix display before syncing Last.fm cover art."
            case .invalidRequest:
                return "OpenMatrix could not create the Last.fm request."
            case .serverResponse:
                return "Last.fm could not be reached. Check your connection and try again."
            case .invalidResponse:
                return "Last.fm returned data OpenMatrix could not read."
            case .artworkUnavailable:
                return "Last.fm did not provide downloadable album artwork for the now-playing track."
            case .syncInProgress:
                return "A Last.fm cover-art sync is already in progress."
            case .api(let message):
                return "Last.fm: \(message)"
            }
        }
    }
}

@MainActor
enum LastFMBackgroundRefresh {
    static func schedule() {
        guard LastFMService.shared.isConfigured,
              IDotMatrixBluetooth.shared.selectedDisplayName != nil else { return }
        let request = BGAppRefreshTaskRequest(identifier: LastFMService.backgroundTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("OpenMatrix could not schedule Last.fm background refresh: %@", error.localizedDescription)
        }
    }

    static func handle(_ task: BGAppRefreshTask) {
        schedule()
        let work = Task { @MainActor in
            do {
                _ = try await LastFMService.shared.syncCurrentTrack(force: false)
                task.setTaskCompleted(success: true)
            } catch {
                NSLog("OpenMatrix Last.fm background sync failed: %@", error.localizedDescription)
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}
