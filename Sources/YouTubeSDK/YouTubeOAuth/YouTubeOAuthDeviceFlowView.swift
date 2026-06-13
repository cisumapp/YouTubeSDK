//
//  YouTubeOAuthDeviceFlowView.swift
//  YouTubeSDK
//
//  SwiftUI sheet for OAuth Device Authorization Grant flow.
//

#if os(iOS) || os(macOS)
import SafariServices
import SwiftUI


public struct YouTubeOAuthDeviceFlowView: View {
    public var onSuccess: (OAuthToken) -> Void
    public var onCancel: () -> Void

    @State private var phase: AuthPhase = .loading
    @State private var activePollingTask: Task<Void, Never>?

    private let deviceFlow = YouTubeOAuthDeviceFlow()

    public init(onSuccess: @escaping (OAuthToken) -> Void, onCancel: @escaping () -> Void) {
        self.onSuccess = onSuccess
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            content
                .navigationTitle("Sign in to YouTube")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            activePollingTask?.cancel()
                            activePollingTask = nil
                            onCancel()
                        }
                    }
                }
        }
        .task {
            await runAuthFlow()
        }
        .onDisappear {
            activePollingTask?.cancel()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Starting authentication...")
                .padding()

        case let .codeReceived(response):
            VStack(spacing: 32) {
                codeSection(response)
                instructionsSection(response)
                statusSection
            }
            .padding(24)

        case let .error(message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.red)

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)

                Button("Try Again") {
                    Task { await runAuthFlow() }
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
        }
    }

    // MARK: - Subviews

    private func codeSection(_ response: DeviceCodeResponse) -> some View {
        VStack(spacing: 12) {
            Text("Enter this code:")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(response.userCode)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                    #if os(iOS)
                        .fill(Color(uiColor: .systemGray5))
                    #else
                        .fill(Color(nsColor: .systemGray))
                    #endif
                )

            Text("Code expires in \(response.expiresIn / 60) minutes")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func instructionsSection(_ response: DeviceCodeResponse) -> some View {
        VStack(spacing: 16) {
            #if os(iOS)
            NavigationLink {
                SafariAuthView {
                    phase = .codeReceived(response)
                }
            } label: {
                HStack {
                    Image(systemName: "safari")
                    Text("Open Google Sign-in Page")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            #else
            Button {
                NSWorkspace.shared.open(URL(string: "https://www.google.com/device")!)
            } label: {
                HStack {
                    Image(systemName: "safari")
                    Text("Open Google Sign-in Page")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            #endif

            Text("Or visit")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Text("google.com/device")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.blue)
        }
    }

    private var statusSection: some View {
        HStack(spacing: 12) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Waiting for authorization...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(height: 24)
    }

    // MARK: - Auth Flow

    private func runAuthFlow() async {
        do {
            let response = try await deviceFlow.startAuth()
            phase = .codeReceived(response)

            let expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn))

            activePollingTask = Task {
                do {
                    let token = try await deviceFlow.pollForToken(
                        deviceCode: response.deviceCode,
                        interval: response.interval,
                        expiresAt: expiresAt
                    )
                    OAuthTokenStorage.save(token)
                    await MainActor.run {
                        if !Task.isCancelled {
                            onSuccess(token)
                        }
                    }
                } catch {
                    await MainActor.run {
                        if !Task.isCancelled {
                            phase = .error(error.localizedDescription)
                        }
                    }
                }
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}

// MARK: - Auth Phase

private enum AuthPhase: Equatable {
    case loading
    case codeReceived(DeviceCodeResponse)
    case error(String)
}

// MARK: - In-App Safari (iOS only)

#if os(iOS)
private struct SafariAuthView: UIViewControllerRepresentable {
    let onClosed: () -> Void

    func makeUIViewController(context: UIViewControllerRepresentableContext<SafariAuthView>) -> SFSafariViewController {
        let config = SFSafariViewController.Configuration()
        config.entersReaderIfAvailable = false
        let safari = SFSafariViewController(
            url: URL(string: "https://www.google.com/device")!,
            configuration: config
        )
        safari.delegate = context.coordinator
        return safari
    }

    func updateUIViewController(_: SFSafariViewController, context _: UIViewControllerRepresentableContext<SafariAuthView>) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onClosed: onClosed)
    }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onClosed: () -> Void

        init(onClosed: @escaping () -> Void) {
            self.onClosed = onClosed
        }

        func safariViewControllerDidClose(_: SFSafariViewController) {
            onClosed()
        }
    }
}
#endif

#endif
