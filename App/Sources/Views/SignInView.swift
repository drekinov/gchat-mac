import AppKit
import SwiftUI

/// The first run, and the window after the last account is removed. An empty sidebar sits beside the call to
/// action, so the window already has the shape it keeps after sign-in.
struct SignInView: View {
    let model: AppModel
    /// Snapshots run without a saved client, so they pass the caption in.
    var snapshotClient: String?

    var body: some View {
        NavigationSplitView {
            placeholderSidebar
                .navigationSplitViewColumnWidth(min: 270, ideal: 330, max: 440)
        } detail: {
            // Centred when it fits; scrolls in a short window instead of clipping.
            GeometryReader { proxy in
                ScrollView {
                    content
                        .frame(maxWidth: 420)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 32)
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var client: String? { snapshotClient ?? model.savedClientProject }

    private var placeholderSidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach([180.0, 130, 156], id: \.self) { width in
                Capsule().fill(Color.primary.opacity(0.08)).frame(width: width, height: 10)
            }
            .accessibilityHidden(true)
            Text("Your spaces and direct messages appear here after you sign in.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var content: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            Text("Add a Google account")
                .font(.title.weight(.semibold))
                .padding(.top, 6)
            Text(
                "Sign-in opens in your browser. Pick the account that belongs to your organization's client and "
                    + "leave every permission ticked."
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            Group {
                if model.isSigningIn { waiting } else { actions }
            }
            .padding(.top, 6)
            if let error = model.signInError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(Theme.error)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            helpBox.padding(.top, 22)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let client {
            VStack(spacing: 8) {
                Button {
                    model.startAddAccount()
                } label: {
                    Text("Sign in with Google").fontWeight(.semibold).padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                Text("Client: \(client)").font(.caption).foregroundStyle(.secondary)
                Button("Use another client file…") { model.startAddAccount(newClient: true) }
                    .buttonStyle(.plain)
                    .fontWeight(.medium)
                    .foregroundStyle(Theme.accentText)
                    .padding(.top, 4)
            }
        } else {
            Button {
                model.startAddAccount(newClient: true)
            } label: {
                Text("Choose client file and sign in…").fontWeight(.semibold).padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
        }
    }

    private var waiting: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Waiting for the browser…")
            Button("Cancel") { model.cancelSignIn() }
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
        .padding(.vertical, 6)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .background(.fill.tertiary, in: Capsule())
    }

    private var helpBox: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No client file yet?").fontWeight(.semibold).foregroundStyle(.primary)
            Text(
                "Someone in your organization sets up a Google Cloud project once and shares a Desktop OAuth client "
                    + "file with the people using Thimble."
            )
            .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .lineSpacing(2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
