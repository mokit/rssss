import SwiftUI
import AppKit
import WebKit

struct WebPreviewPaneView: View {
    @EnvironmentObject private var logStore: AppLogStore
    let request: PreviewRequest
    let onClose: () -> Void

    @State private var reloadToken = UUID()
    @State private var pageTitle: String?
    @State private var currentURL: URL
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var lastLoggedLoadErrorSignature: String?

    init(request: PreviewRequest, onClose: @escaping () -> Void) {
        self.request = request
        self.onClose = onClose
        _currentURL = State(initialValue: request.url)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ZStack {
                EmbeddedWebView(
                    url: request.url,
                    reloadToken: reloadToken,
                    onStateChange: updateState
                )

                if let errorMessage {
                    errorOverlay(message: errorMessage)
                } else if isLoading {
                    ProgressView("Loading page...")
                        .padding(14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .onChange(of: request.url) { _, newURL in
            currentURL = newURL
            pageTitle = nil
            errorMessage = nil
            lastLoggedLoadErrorSignature = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(headerTitle)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Button("Open in Browser") {
                NSWorkspace.shared.open(currentURL)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                reloadToken = UUID()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reload")

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close Preview")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var headerTitle: String {
        if let pageTitle, !pageTitle.isEmpty {
            return pageTitle
        }
        if !request.title.isEmpty {
            return request.title
        }
        if let host = currentURL.host, !host.isEmpty {
            return host
        }
        return currentURL.absoluteString
    }

    private func updateState(_ state: EmbeddedWebView.NavigationState) {
        pageTitle = state.title
        currentURL = state.url ?? request.url
        isLoading = state.isLoading
        errorMessage = state.errorMessage
        if state.errorMessage == nil {
            lastLoggedLoadErrorSignature = nil
            return
        }
        logLoadErrorIfNeeded(state: state)
    }

    private func logLoadErrorIfNeeded(state: EmbeddedWebView.NavigationState) {
        guard let errorMessage = state.errorMessage else { return }
        let url = (state.url ?? request.url).absoluteString
        let signature = "\(url)|\(errorMessage)"
        guard signature != lastLoggedLoadErrorSignature else { return }
        lastLoggedLoadErrorSignature = signature
        logStore.add(
            "Inline preview load failed: title=\"\(request.title)\", url=\(url), error=\(errorMessage)"
        )
    }

    @ViewBuilder
    private func errorOverlay(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Unable to load page")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding()
    }
}

private struct EmbeddedWebView: NSViewRepresentable {
    struct NavigationState {
        let title: String?
        let url: URL?
        let isLoading: Bool
        let errorMessage: String?
    }

    let url: URL
    let reloadToken: UUID
    let onStateChange: (NavigationState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStateChange: onStateChange)
    }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onStateChange = onStateChange
        context.coordinator.update(webView: webView, url: url, reloadToken: reloadToken)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var onStateChange: (NavigationState) -> Void
        private var loadedURL: URL?
        private var latestReloadToken: UUID?

        init(onStateChange: @escaping (NavigationState) -> Void) {
            self.onStateChange = onStateChange
        }

        func update(webView: WKWebView, url: URL, reloadToken: UUID) {
            if loadedURL != url {
                loadedURL = url
                latestReloadToken = reloadToken
                webView.load(URLRequest(url: url))
                publish(from: webView, isLoading: true, errorMessage: nil)
                return
            }

            if latestReloadToken != reloadToken {
                latestReloadToken = reloadToken
                webView.reload()
                publish(from: webView, isLoading: true, errorMessage: nil)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            publish(from: webView, isLoading: true, errorMessage: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            publish(from: webView, isLoading: false, errorMessage: nil)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            publish(from: webView, isLoading: false, errorMessage: error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            publish(from: webView, isLoading: false, errorMessage: error.localizedDescription)
        }

        private func publish(from webView: WKWebView, isLoading: Bool, errorMessage: String?) {
            onStateChange(
                NavigationState(
                    title: webView.title,
                    url: webView.url,
                    isLoading: isLoading,
                    errorMessage: errorMessage
                )
            )
        }
    }
}
