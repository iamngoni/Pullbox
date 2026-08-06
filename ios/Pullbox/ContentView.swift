import Photos
import PullboxCore
import SwiftUI
import UIKit

struct ContentView: View {
    @AppStorage("serverURL.v2") private var serverURL = "https://pullbox.antonlabs.cc"
    @State private var source = ""
    @State private var media: MediaInfo?
    @State private var phase: Phase = .idle
    @State private var showingSettings = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0x090B10), Color(hex: 0x111827)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    inputCard
                    if let media { mediaCard(media) }
                    status
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
            }
        }
        .tint(.mint)
        .sheet(isPresented: $showingSettings) {
            SettingsView(serverURL: $serverURL)
                .presentationDetents([.height(260)])
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text("PULLBOX")
                    .font(.system(size: 13, weight: .black, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(.mint)
                Text("Save it.\nKeep it.")
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .tracking(-1.2)
            }
            Spacer()
            Button { showingSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .accessibilityLabel("Backend settings")
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Image(systemName: "link")
                    .foregroundStyle(.mint)
                Text("Media link")
                    .font(.headline)
                Spacer()
                Button("Paste") {
                    source = UIPasteboard.general.string ?? ""
                    media = nil
                }
                .font(.subheadline.bold())
                .foregroundStyle(.mint)
            }

            TextField("https://…", text: $source, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .focused($inputFocused)
                .lineLimit(2...4)
                .padding(15)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

            Button(action: analyze) {
                HStack {
                    if phase == .analyzing {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(phase == .analyzing ? "Checking link…" : "Check link")
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(.mint, in: RoundedRectangle(cornerRadius: 16))
            }
            .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase.isBusy)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26))
        .overlay {
            RoundedRectangle(cornerRadius: 26)
                .stroke(.white.opacity(0.09), lineWidth: 1)
        }
    }

    private func mediaCard(_ media: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            AsyncImage(url: media.thumbnail) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "play.rectangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 20))

            VStack(alignment: .leading, spacing: 6) {
                Text(media.title)
                    .font(.title3.bold())
                    .lineLimit(3)
                if let duration = media.duration {
                    Label(duration.formattedDuration, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: downloadAndSave) {
                HStack {
                    if phase == .downloading || phase == .saving {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down.fill")
                    }
                    Text(phase.actionTitle)
                    Spacer()
                    Image(systemName: "photo.on.rectangle")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 56)
                .background(Color(hex: 0x6D5DFC), in: RoundedRectangle(cornerRadius: 17))
            }
            .disabled(phase.isBusy)
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 26))
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .success:
            Label("Saved to Photos", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.mint)
                .font(.headline)
                .transition(.scale.combined(with: .opacity))
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(red: 1, green: 0.55, blue: 0.45))
                .font(.subheadline)
        default:
            EmptyView()
        }
    }

    private func analyze() {
        inputFocused = false
        media = nil
        phase = .analyzing
        Task {
            do {
                let sourceURL = try validatedSourceURL()
                let client = try makeClient()
                media = try await client.analyze(sourceURL: sourceURL)
                phase = .idle
            } catch {
                phase = .failure(error.localizedDescription)
            }
        }
    }

    private func downloadAndSave() {
        phase = .downloading
        Task {
            do {
                let sourceURL = try validatedSourceURL()
                let client = try makeClient()
                let localURL = try await client.download(sourceURL: sourceURL)
                phase = .saving
                try await PhotoSaver.saveVideo(at: localURL)
                try? FileManager.default.removeItem(at: localURL)
                withAnimation(.spring(response: 0.35)) { phase = .success }
            } catch {
                phase = .failure(error.localizedDescription)
            }
        }
    }

    private func validatedSourceURL() throws -> URL {
        guard let url = URL(string: source.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw AppError.invalidSource
        }
        return url
    }

    private func makeClient() throws -> APIClient {
        guard let baseURL = URL(string: serverURL),
              ["http", "https"].contains(baseURL.scheme?.lowercased()) else {
            throw AppError.invalidServer
        }
        return APIClient(baseURL: baseURL)
    }
}

private struct SettingsView: View {
    @Binding var serverURL: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Private Actix backend") {
                    TextField("http://192.168.1.10:8787", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Use your Mac’s LAN address when running on your iPhone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connection")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private enum Phase: Equatable {
    case idle, analyzing, downloading, saving, success, failure(String)

    var isBusy: Bool {
        self == .analyzing || self == .downloading || self == .saving
    }

    var actionTitle: String {
        switch self {
        case .downloading: "Downloading…"
        case .saving: "Saving…"
        default: "Save to Photos"
        }
    }
}

private enum AppError: LocalizedError {
    case invalidSource, invalidServer

    var errorDescription: String? {
        switch self {
        case .invalidSource: "Paste a valid http or https link."
        case .invalidServer: "Set a valid backend address in Settings."
        }
    }
}

private enum PhotoSaver {
    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { saved, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if saved {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoError.saveFailed)
                }
            }
        }
    }
}

private enum PhotoError: LocalizedError {
    case permissionDenied, saveFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Allow Pullbox to add videos to Photos."
        case .saveFailed: "The video could not be saved to Photos."
        }
    }
}

private extension Double {
    var formattedDuration: String {
        let total = Int(self.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
