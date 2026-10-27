import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var bluetooth = IDotMatrixBluetooth.shared
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var showsOtherDevices = false
    @State private var statusMessage = "Choose a display and image to get started."
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.10, green: 0.12, blue: 0.16), Color(red: 0.06, green: 0.08, blue: 0.12)]
                    : [Color(red: 0.96, green: 0.97, blue: 0.99), Color(red: 0.91, green: 0.95, blue: 1.0)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        displayPicker
                        imagePicker
                        sendButton
                        Text(statusMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("statusMessage")
                        Text(bluetooth.bluetoothStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("bluetoothStatus")
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .toolbar(.hidden, for: .navigationBar)
                .alert("OpenMatrix", isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )) {
                    if errorMessage?.contains("Settings") == true {
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
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text("OpenMatrix")
                    .font(.title2.weight(.bold))
                Text("Send an image to your pixel display")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
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
                ForEach(likelyDisplays) { display in
                    displayRow(display)
                }

                if !otherDisplays.isEmpty {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showsOtherDevices.toggle()
                        }
                    } label: {
                        Label(
                            showsOtherDevices ? "Show fewer devices" : "Show more devices (\(otherDisplays.count))",
                            systemImage: showsOtherDevices ? "chevron.up" : "chevron.down"
                        )
                        .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 4)

                    if showsOtherDevices {
                        ForEach(otherDisplays) { display in
                            displayRow(display)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var likelyDisplays: [MatrixDisplay] {
        bluetooth.displays.filter(\.isLikelyIDotMatrix)
    }

    private var otherDisplays: [MatrixDisplay] {
        bluetooth.displays.filter { !$0.isLikelyIDotMatrix }
    }

    private func displayRow(_ display: MatrixDisplay) -> some View {
        Button {
            bluetooth.select(display)
            statusMessage = "Selected target: \(display.name)."
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
                HStack(spacing: 12) {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("No image selected")
                            .font(.headline)
                        Text("Choose a photo to preview it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 72)
                .padding(.horizontal, 16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
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
                    let acknowledged = try await bluetooth.sendImage(imageData)
                    let displayName = bluetooth.selectedDisplayName ?? "your display"
                    statusMessage = acknowledged
                        ? "Bluetooth acknowledged the transfer to \(displayName); image rendering is not confirmed."
                        : "Transfer sent to \(displayName) without a Bluetooth write acknowledgement."
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
