import SwiftUI
import AppKit
import ApplicationServices

struct PermissionsView: View {
    let onContinue: () -> Void

    @State private var isTrusted: Bool = AXIsProcessTrusted()
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)

            Text("Welcome to NovaClipboard")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("NovaClipboard needs **Accessibility** permission to:")
                Label("Paste items by simulating ⌘V into the active app", systemImage: "keyboard")
                Label("Detect caret bounds so the panel appears next to the cursor", systemImage: "cursorarrow.rays")
            }
            .padding(.horizontal, 12)

            if isTrusted {
                Label("Accessibility permission granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Button("Continue", action: onContinue)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button {
                    openAccessibilityPane()
                } label: {
                    Label("Open System Settings", systemImage: "arrow.up.right.square")
                }
                .controlSize(.large)

                Text("Waiting for permission…")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(30)
        .frame(width: 460, height: 380)
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
