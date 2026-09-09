import Foundation
import PullboxCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

private let pullboxAccent = Color(red: 0.345, green: 0.278, blue: 0.91)

@MainActor
final class ShareViewModel: ObservableObject {
    enum State {
        case readingLink
        case resolving(URL)
        case ready(MediaInfo, requestID: UUID)
        case queueing(MediaInfo)
        case failure(String, retryURL: URL?)

        var isQueueing: Bool {
            if case .queueing = self { return true }
            return false
        }
    }

    @Published var state: State = .readingLink
}

@MainActor
private final class ShareBackgroundTransferRuntime {
    static let shared = ShareBackgroundTransferRuntime()

    let enqueuer: SystemBackgroundTransferEnqueuer
    private let delegate: PullboxBackgroundSessionDelegate

    private init() {
        let delegate = PullboxBackgroundSessionDelegate(
            photoSaver: SystemPhotoLibrarySaver()
        )
        self.delegate = delegate
        self.enqueuer = SystemBackgroundTransferEnqueuer(delegate: delegate)
    }
}

final class ShareViewController: UIViewController {
    private let model = ShareViewModel()
    private var hostingController: UIHostingController<ShareExtensionView>?
    private var workTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        let content = ShareExtensionView(
            model: model,
            onCancel: { [weak self] in self?.cancel() },
            onDownload: { [weak self] media, requestID in
                self?.confirmDownload(media, requestID: requestID)
            },
            onRetry: { [weak self] url in self?.startResolving(url) }
        )
        let hostingController = UIHostingController(rootView: content)
        self.hostingController = hostingController

        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)

        loadSharedURL()
    }

    private func loadSharedURL() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            model.state = .failure("Pullbox could not read the shared item.", retryURL: nil)
            return
        }

        let providers = items.compactMap(\.attachments).flatMap { $0 }
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            load(provider, typeIdentifier: UTType.url.identifier)
            return
        }

        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            load(provider, typeIdentifier: UTType.plainText.identifier)
            return
        }

        model.state = .failure("Share a web link with Pullbox.", retryURL: nil)
    }

    private func load(_ provider: NSItemProvider, typeIdentifier: String) {
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { [weak self] item, _ in
            let value: String?
            if let url = item as? URL {
                value = url.absoluteString
            } else if let url = item as? NSURL {
                value = url.absoluteString
            } else if let text = item as? String {
                value = text
            } else {
                value = nil
            }

            Task { @MainActor [weak self, value] in
                guard let self else { return }
                if let value, let url = ShareURLExtractor.firstWebURL(in: value) {
                    self.startResolving(url)
                } else {
                    self.model.state = .failure(
                        "Pullbox could not find a web link in this item.",
                        retryURL: nil
                    )
                }
            }
        }
    }

    @MainActor
    private func startResolving(_ url: URL) {
        workTask?.cancel()
        model.state = .resolving(url)
        let flow = makeFlow()

        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let media = try await flow.resolve(sourceURL: url)
                try Task.checkCancellation()
                self.model.state = .ready(media, requestID: UUID())
            } catch is CancellationError {
                return
            } catch {
                self.model.state = .failure(error.localizedDescription, retryURL: url)
            }
        }
    }

    @MainActor
    private func confirmDownload(_ media: MediaInfo, requestID: UUID) {
        guard !model.state.isQueueing else { return }
        workTask?.cancel()
        model.state = .queueing(media)
        let flow = makeFlow()

        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await flow.confirmDownload(for: media, requestID: requestID)
                // Only the user's Download tap reaches this durable handoff. Once the
                // system owns the transfer, dismiss immediately without waiting for it.
                self.finish()
            } catch {
                self.model.state = .failure(error.localizedDescription, retryURL: media.sourceURL)
            }
        }
    }

    private func makeFlow() -> ShareSheetDownloadFlow {
        let baseURL = BackgroundDownloadHandoff.resolveBaseURL()
        return ShareSheetDownloadFlow(
            analyzer: APIClient(baseURL: baseURL),
            queue: SystemShareDownloadQueue(
                baseURL: baseURL,
                backgroundEnqueuer: ShareBackgroundTransferRuntime.shared.enqueuer
            )
        )
    }

    private func cancel() {
        workTask?.cancel()
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}

struct ShareExtensionView: View {
    @ObservedObject var model: ShareViewModel
    let onCancel: () -> Void
    let onDownload: (MediaInfo, UUID) -> Void
    let onRetry: (URL) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    brandMark

                    VStack(spacing: 8) {
                        Text(title)
                            .font(.title2.weight(.bold))
                        Text(message)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    stateContent
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemBackground))
            .toolbar {
                if !model.state.isQueueing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                        }
                        .accessibilityLabel("Cancel")
                    }
                }
            }
        }
        .tint(pullboxAccent)
        .preferredColorScheme(.light)
    }

    private var brandMark: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 18)
                .fill(pullboxAccent.opacity(0.08))
                .frame(width: 72, height: 72)
            Image(systemName: "link")
                .font(.title.weight(.semibold))
                .foregroundStyle(pullboxAccent)
                .frame(width: 72, height: 72)
            Image(systemName: "arrow.down")
                .font(.caption.weight(.black))
                .foregroundStyle(pullboxAccent)
                .padding(9)
        }
    }

    private var title: String {
        switch model.state {
        case .readingLink: return "Save with Pullbox"
        case .resolving: return "Resolving link"
        case .ready: return "Ready to download"
        case .queueing: return "Starting download"
        case .failure: return "Couldn’t prepare link"
        }
    }

    private var message: String {
        switch model.state {
        case .readingLink:
            return "Reading the shared link."
        case .resolving(let url):
            return "Checking \(url.host() ?? "the shared link") with Pullbox."
        case .ready:
            return "Review the resolved media, then tap Download."
        case .queueing:
            return "Handing the download to iOS. This sheet will close automatically."
        case .failure(let message, _):
            return message
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .readingLink:
            ProgressView("Reading link…")
                .frame(maxWidth: .infinity, minHeight: 140)
        case .resolving:
            ProgressView("Resolving media…")
                .frame(maxWidth: .infinity, minHeight: 140)
        case .ready(let media, let requestID):
            preview(media, requestID: requestID)
        case .queueing:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Queueing background download…")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        case .failure(_, let retryURL):
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Color(uiColor: .systemOrange))
                if let retryURL {
                    Button("Try Again") { onRetry(retryURL) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        }
    }

    private func preview(_ media: MediaInfo, requestID: UUID) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let thumbnail = media.thumbnail {
                AsyncImage(url: thumbnail) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ZStack {
                        Color(uiColor: .secondarySystemBackground)
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(media.title)
                    .font(.headline)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    if let host = media.sourceURL.host() {
                        Text(host)
                    }
                    if let duration = media.duration {
                        Text("•")
                        Text(duration.formattedDuration)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button {
                onDownload(media, requestID)
            } label: {
                Label("Download", systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .accessibilityLabel("Download resolved media")

            Label(
                "After you tap Download, Pullbox queues the transfer and closes this sheet.",
                systemImage: "arrow.down.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
    }
}

private extension Double {
    var formattedDuration: String {
        let total = Int(rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
