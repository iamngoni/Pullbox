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
        case queued(URL)
        case failure(String)
    }

    @Published var state: State = .readingLink
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
            onDone: { [weak self] in self?.finish() }
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
            model.state = .failure("Pullbox could not read the shared item.")
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

        model.state = .failure("Share a web link with Pullbox.")
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
                    await self.enqueueAndDismiss(url)
                } else {
                    self.model.state = .failure("Pullbox could not find a web link in this item.")
                }
            }
        }
    }

    // MARK: - Queue + Immediate Dismiss (CEO requirement)

    private func enqueueAndDismiss(_ url: URL) async {
        workTask?.cancel()
        workTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Durable enqueue + system-owned background transfer + Live Activity (awaited before dismiss)
                let baseURL = BackgroundDownloadHandoff.resolveBaseURL()
                _ = try await BackgroundDownloadHandoff.enqueueAndNotify(
                    sourceURL: url,
                    store: nil,
                    activityManager: nil,
                    baseURL: baseURL,
                    backgroundEnqueuer: SystemBackgroundTransferEnqueuer()
                )
                // Success: show queued briefly then dismiss immediately
                self.model.state = .queued(url)
                // Ensure Live Activity is visible before teardown (already awaited above)
                try? await Task.sleep(nanoseconds: 700_000_000)
                self.finish()
            } catch {
                // Enqueue failure handled without falsely reporting success
                self.model.state = .failure(error.localizedDescription)
            }
        }
        await workTask?.value
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
    let onDone: () -> Void

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
                ToolbarItem(placement: .cancellationAction) {
                    if case .queued = model.state {
                        Button("Done", action: onDone)
                            .fontWeight(.semibold)
                    } else {
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
        case .queued: return "Queued for Pullbox"
        case .failure: return "Couldn’t queue link"
        case .readingLink: return "Save with Pullbox"
        }
    }

    private var message: String {
        switch model.state {
        case .readingLink: return "Reading the shared link."
        case .queued(let url):
            if let host = url.host() {
                return "Handed \(host) to Pullbox. Follow progress in the Live Activity."
            }
            return "Handed to Pullbox for download. Follow progress in the Live Activity."
        case .failure(let message): return message
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch model.state {
        case .readingLink:
            ProgressView("Reading link…")
                .frame(maxWidth: .infinity, minHeight: 140)
        case .queued:
            VStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Color(red: 0.118, green: 0.725, blue: 0.561))
                Text("Queued — Pullbox will download and save it. You can close this sheet.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                // Live Activity hint
                Label("Check Live Activity / Dynamic Island for progress", systemImage: "chart.bar.doc.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .transition(.scale.combined(with: .opacity))
        case .failure:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Color(uiColor: .systemOrange))
                Text("Try sharing again. If the link is private, Pullbox can only save public media.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 140)
        }
    }
}
