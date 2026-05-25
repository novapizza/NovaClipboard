import SwiftUI
import AppKit
import ApplicationServices

struct PermissionsView: View {
    let onContinue: () -> Void

    @State private var isTrusted: Bool = AXIsProcessTrusted()
    @State private var pollTimer: Timer?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.22),
                    Color.purple.opacity(0.12),
                    Color.blue.opacity(0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "doc.on.clipboard.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 96, height: 96)
                    .liquidGlass(.regular, in: .circle)

                Text("Welcome to NovaClipboard")
                    .font(.title2.bold())

                VStack(alignment: .leading, spacing: 10) {
                    Text("NovaClipboard needs **Accessibility** permission to:")
                        .font(.subheadline)
                    Label("Paste items by simulating ⌘V into the active app", systemImage: "keyboard")
                    Label("Detect caret bounds so the panel appears next to the cursor", systemImage: "cursorarrow.rays")
                }
                .font(.callout)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .liquidGlass(.regular, in: .roundedRect(cornerRadius: 16))
                .padding(.horizontal, 8)

                if isTrusted {
                    Label("Accessibility permission granted", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .liquidGlass(.regular, in: .capsule)
                    Button(action: onContinue) {
                        Text("Continue").frame(minWidth: 120)
                    }
                    .buttonStyle(.liquidGlass(tint: .accentColor, prominent: true))
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button {
                        openAccessibilityPane()
                    } label: {
                        Label("Open System Settings", systemImage: "arrow.up.right.square")
                            .frame(minWidth: 200)
                    }
                    .buttonStyle(.liquidGlass(tint: .accentColor, prominent: true))

                    Text("Waiting for permission…")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }
            .padding(30)
        }
        .frame(width: 460, height: 420)
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                let trusted = AXIsProcessTrusted()
                if trusted != isTrusted {
                    isTrusted = trusted
                }
                if trusted {
                    stopPolling()
                    onContinue()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func openAccessibilityPane() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        _ = AXIsProcessTrustedWithOptions([prompt: kCFBooleanTrue] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
