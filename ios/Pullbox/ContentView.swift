import Photos
import PullboxCore
import SwiftUI
import UIKit
import Combine

struct ContentView: View {
    @AppStorage("serverURL.v2") private var serverURL = "https://pullbox.antonlabs.cc"
    @State private var source = ""
    @State private var media: MediaInfo?
    @State private var phase: Phase = .idle
    @State private var showingSettings = false
    @State private var queuedItems: [QueuedDownload] = []
    @FocusState private var inputFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                if !queuedItems.isEmpty {
                    queuedSection
                }

                if let media {
                    preview(media)
                } else {
                    linkComposer
                }

                status
                Spacer(minLength: 16)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .tint(.accentColor)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showingSettings) {
            SettingsView(serverURL: $serverURL)
                .presentationDetents([.height(300)])
                .preferredColorScheme(.light)
        }
        .onAppear {
            syncServerURLToAppGroup()
            reloadQueue()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pullboxQueueUpdated)) { _ in
            reloadQueue()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pullboxDownloadProgress)) { _ in
            reloadQueue()
        }
        .onChange(of: serverURL) {
            syncServerURLToAppGroup()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            reloadQueue()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 44, height: 44)
                Image(systemName: "link")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                Image(systemName: "arrow.down")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(Color.accentColor)
                    .padding(5)
            }

            Text("Pullbox")
                .font(.title2.weight(.bold))

            Spacer()

            Button { showingSettings = true } label: {
                Image(systemName: "ellipsis")
                    .font(.headline)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .accessibilityLabel("Backend settings")
        }
    }

    private var queuedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Queued Downloads")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if queuedItems.contains(where: { $0.status == .queued || $0.status == .preparing || $0.status == .saving || {
                    if case .downloading = $0.status { return true }; return false
                }($0) }) {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            ForEach(queuedItems) { item in
                queuedRow(item)
            }
            Text("Queued via Share Sheet — transfers continue after the sheet closes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(uiColor: .separator), lineWidth: 0.75)
        }
    }

    private func queuedRow(_ item: QueuedDownload) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(color(for: item.status).opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: icon(for: item.status))
                    .foregroundStyle(color(for: item.status))
                    .font(.subheadline.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? item.sourceURL.host() ?? "Shared link")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(item.sourceURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(detail(for: item.status))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color(for: item.status))
            }
            Spacer()
            if case .downloading(let p) = item.status, let prog = p {
                Text("\(Int((prog * 100).rounded()))%")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
            } else if case .failed(let msg) = item.status {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .help(msg)
            }
        }
        .padding(.vertical, 4)
    }

    private func icon(for status: DownloadStatus) -> String {
        switch status {
        case .queued: return "clock.fill"
        case .preparing: return "gearshape.fill"
        case .downloading: return "arrow.down.circle.fill"
        case .saving: return "photo.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func color(for status: DownloadStatus) -> Color {
        switch status {
        case .queued: return .secondary
        case .preparing: return .orange
        case .downloading: return .accentColor
        case .saving: return .purple
        case .succeeded: return .green
        case .failed: return .red
        }
    }

    private func detail(for status: DownloadStatus) -> String {
        switch status {
        case .queued: return "Queued"
        case .preparing: return "Preparing"
        case .downloading(let p):
            if let prog = p { return "Downloading \(Int((prog*100).rounded()))%" }
            return "Downloading"
        case .saving: return "Saving to Photos"
        case .succeeded: return "Saved"
        case .failed(let msg): return msg
        }
    }

    private var linkComposer: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("PRIVATE DOWNLOADER")
                    .font(.caption.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)

                Text("Keep what matters.")
                    .font(.largeTitle.weight(.bold))

                Text("Paste a permitted media link and save it straight to Photos.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "link")
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 3)

                    TextField("Paste a media link", text: $source, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($inputFocused)
                        .lineLimit(3...5)
                }

                HStack {
                    Text(source.isEmpty ? "HTTP or HTTPS" : "Ready to preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(action: analyze) {
                        Group {
                            if phase == .analyzing {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.right")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.circle)
                    .controlSize(.large)
                    .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || phase.isBusy)
                    .accessibilityLabel(phase == .analyzing ? "Previewing link" : "Preview link")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 158, alignment: .topLeading)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color(uiColor: .separator), lineWidth: 0.75)
            }

            Button(action: pasteFromClipboard) {
                Label("Paste from Clipboard", systemImage: "clipboard")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(uiColor: .separator), lineWidth: 0.75)
            }

            steps

            Label {
                Text("Your link is sent only to your private Pullbox server.")
                    .font(.subheadline)
                    .foregroundStyle(Color.accentColor)
            } icon: {
                Image(systemName: "lock")
                    .foregroundStyle(Color.accentColor)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private var steps: some View {
        HStack(spacing: 8) {
            step("Paste", systemImage: "link", isHighlighted: true)
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1)
            step("Preview", systemImage: "play", isHighlighted: false)
            Rectangle()
                .fill(Color(uiColor: .separator))
                .frame(height: 1)
            step("Save", systemImage: "arrow.down", isHighlighted: false)
        }
        .padding(.vertical, 4)
    }

    private func step(_ title: String, systemImage: String, isHighlighted: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)
                .frame(width: 40, height: 40)
                .background(
                    isHighlighted ? Color.accentColor.opacity(0.08) : Color(uiColor: .secondarySystemBackground),
                    in: Circle()
                )
            Text(title)
                .font(.caption)
                .foregroundStyle(isHighlighted ? Color.primary : Color.secondary)
        }
    }

    private func preview(_ media: MediaInfo) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Preview")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            AsyncImage(url: media.thumbnail) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    Image(systemName: "play.rectangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 18))

            VStack(alignment: .leading, spacing: 5) {
                Text(media.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(3)

                if let host = media.sourceURL.host() {
                    Text(host)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                detail("MP4", caption: "Format")

                if let duration = media.duration {
                    Rectangle()
                        .fill(Color(uiColor: .separator))
                        .frame(width: 1, height: 38)

                    detail(duration.formattedDuration, caption: "Duration")
                }
            }
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .stroke(Color(uiColor: .separator), lineWidth: 0.75)
            }

            Button(action: downloadAndSave) {
                HStack(spacing: 10) {
                    if phase == .downloading || phase == .saving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text(phase.actionTitle)
                    Spacer()
                    Image(systemName: "photo")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .frame(minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 16))
            .disabled(phase.isBusy || phase == .success)

            Button("Replace link", systemImage: "arrow.triangle.2.circlepath", action: replaceLink)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .disabled(phase.isBusy)
        }
    }

    private func detail(_ value: String, caption: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .success:
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Color(hex: 0x1EB98F))
                Text("Saved to Photos")
                    .font(.headline)
                Spacer()
            }
                .padding(16)
                .background(Color(hex: 0x1EB98F).opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                .transition(.scale.combined(with: .opacity))
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(uiColor: .systemRed))
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .systemRed).opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        default:
            EmptyView()
        }
    }

    private func pasteFromClipboard() {
        source = UIPasteboard.general.string ?? ""
        media = nil
        phase = .idle
        inputFocused = true
    }

    private func replaceLink() {
        withAnimation(.easeInOut(duration: 0.2)) {
            source = ""
            media = nil
            phase = .idle
        }
        inputFocused = true
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
                try await PhotoSaver.save(at: localURL)
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

    // MARK: - Queue handling

    private func syncServerURLToAppGroup() {
        UserDefaults(suiteName: BackgroundDownloadHandoff.appGroupIdentifier)?.set(serverURL, forKey: "serverURL.v2")
    }

    private func reloadQueue() {
        let store = FileQueueStore(appGroupIdentifier: BackgroundDownloadHandoff.appGroupIdentifier)
        queuedItems = (try? store.load()) ?? []
        // Sort: queued first, then by createdAt descending
        queuedItems.sort { a, b in
            // Keep active work above completed downloads, newest first within each group.
            if a.status == .succeeded && b.status != .succeeded { return false }
            if b.status == .succeeded && a.status != .succeeded { return true }
            return a.createdAt > b.createdAt
        }
    }
}

struct AppPhotoSaver: PhotoLibrarySaving {
    func save(at url: URL) async throws {
        try await PhotoSaver.save(at: url)
    }
}

private struct SettingsView: View {
    @Binding var serverURL: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Private Actix backend") {
                    TextField("https://pullbox.example.com", text: $serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Text("Use the hosted Pullbox address or your Mac’s LAN address.")
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
        case .saving: "Saving to Photos…"
        case .success: "Saved to Photos"
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

enum PhotoSaver {
    static func saveVideo(at url: URL) async throws {
        try await save(at: url)
    }
    static func save(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw PhotoError.permissionDenied
        }
        let ext = url.pathExtension.lowercased()
        let isImage = ["jpg","jpeg","png","heic","heif","webp"].contains(ext)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                if isImage {
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                } else {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            } completionHandler: { saved, error in
                if let error {
                    continuation.resume(throwing: PhotoError.from(error))
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
    case permissionDenied, invalidResource, notEnoughSpace, saveFailed

    static func from(_ error: Error) -> Error {
        let photoError = error as NSError
        guard photoError.domain == PHPhotosErrorDomain else { return error }

        switch photoError.code {
        case 3302: return invalidResource
        case 3305: return notEnoughSpace
        default: return error
        }
    }

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Allow Pullbox to add media to Photos."
        case .invalidResource: "Photos rejected this video file. Try the link again to download a fresh iPhone-compatible copy."
        case .notEnoughSpace: "Your iPhone needs more free space before this video can be saved."
        case .saveFailed: "The media could not be saved to Photos."
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
