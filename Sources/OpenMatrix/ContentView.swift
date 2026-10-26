import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var bluetooth = IDotMatrixBluetooth.shared
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var statusMessage = "Choose a display and image to get started."
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                displayPicker
                imagePicker
                sendButton
                Text(statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("statusMessage")
                Text(bluetooth.bluetoothStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("bluetoothStatus")
                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("OpenMatrix")
            .alert("OpenMatrix", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                if errorMessage?.contains("Settings > Privacy") == true {
                    Button("Open Settings") {
                        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                        UIApplication.shared.open(settingsURL)
                    }
                }
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task(id: selectedPhoto) {
                guard let selectedPhoto else { return }
                do {
                    guard let data = try await selectedPhoto.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        throw ImageSelectionError.unreadable
                    }
                    imageData = data
                    previewImage = image
                    statusMessage = "Image ready for a 32 × 32 display."
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private var displayPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Display", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        do {
                            try await bluetooth.scan()
                            statusMessage = bluetooth.displays.isEmpty ? "No devices found." : "Select your display."
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    if bluetooth.isScanning {
                        ProgressView()
                    } else {
                        Text("Scan")
                    }
                }
                .disabled(bluetooth.isScanning || bluetooth.isSending)
            }

            if bluetooth.displays.isEmpty {
                Text(bluetooth.selectedDisplayName ?? "No display selected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bluetooth.displays) { display in
                    Button {
                        bluetooth.select(display)
                        statusMessage = "Connected target: \(display.name)."
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(display.name)
                                Text("\(display.isLikelyIDotMatrix ? "iDotMatrix candidate" : "Nearby BLE device") · \(display.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if bluetooth.selectedDisplayName == display.name {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var imagePicker: some View {
        VStack(spacing: 12) {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240, maxHeight: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Selected image preview")
            } else {
                ContentUnavailableView("No Image", systemImage: "photo", description: Text("Choose an image to send"))
                    .frame(height: 180)
            }

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                Label("Choose Image", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }

    private var sendButton: some View {
        Button {
            guard let imageData else { return }
            Task {
                do {
                    statusMessage = "Sending image…"
                    try await bluetooth.sendImage(imageData)
                    statusMessage = "Image sent to \(bluetooth.selectedDisplayName ?? "your display")."
                } catch {
                    errorMessage = error.localizedDescription
                    statusMessage = "Image could not be sent."
                }
            }
        } label: {
            if bluetooth.isSending {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else {
                Label("Send to Display", systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(imageData == nil || bluetooth.isSending)
    }

    private enum ImageSelectionError: LocalizedError {
        case unreadable

        var errorDescription: String? {
            "The selected image could not be loaded."
        }
    }
}
