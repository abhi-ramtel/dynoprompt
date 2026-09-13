//
//  ModelManagerView.swift
//  DynoPrompt
//
//  The speech-model library: what's available, what's installed, what's
//  active, and where it all lives on disk.
//
//  Two principles shape this screen:
//
//  * **Nothing downloads by itself.** Opening this view makes no network
//    request — the catalog is compiled into the app. A download starts only
//    when the user presses Download, and only after they have been shown the
//    disk and memory cost.
//  * **Say where things are.** The storage path is on screen with a button to
//    reveal it, because "local model" means nothing if you can't find it.
//

import AppKit
import SwiftUI

struct ModelManagerView: View {

    @Environment(\.dismiss) private var dismiss
    var manager: SpeechModelManager
    // Bindable so the active-model selection redraws when it changes: the
    // stored value lives here, not on the manager.
    @Bindable var settings: NotchSettings

    @State private var pendingDownload: SpeechModelDescriptor?
    @State private var pendingRemoval: SpeechModelDescriptor?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modelList
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .onAppear { manager.refresh() }
        .confirmationDialog(
            pendingDownload.map { "Download \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { pendingDownload != nil },
                set: { if !$0 { pendingDownload = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDownload
        ) { model in
            Button("Download") {
                manager.download(model)
                pendingDownload = nil
            }
            Button("Cancel", role: .cancel) { pendingDownload = nil }
        } message: { model in
            Text(downloadConsentMessage(for: model))
        }
        .confirmationDialog(
            pendingRemoval.map { "Delete \($0.displayName)?" } ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { model in
            Button("Delete", role: .destructive) {
                manager.remove(model)
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { model in
            Text("The file will be removed from this Mac. You can download it again later.")
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Speech Models")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("Models run entirely on this Mac. Your microphone audio is never uploaded.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - List

    private var modelList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(SpeechModelCatalog.all) { model in
                    row(for: model)
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    private func row(for model: SpeechModelDescriptor) -> some View {
        let isInstalled = manager.isInstalled(model)
        let isActive = settings.activeSpeechModelID == model.id
        let state = manager.state(for: model)
        let bundled = manager.installedModel(withID: model.id)?.isBundled ?? false

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.displayName)
                    .font(.system(size: 13, weight: .medium))

                if isActive {
                    tag("Active", color: .accentColor)
                } else if isInstalled {
                    tag(bundled ? "Built-in" : "Installed", color: .green)
                }

                Spacer()
                actionControls(for: model, isInstalled: isInstalled, isActive: isActive, state: state)
            }

            Text(model.summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            if manager.isMemoryHeavy(model) {
                Label(
                    "Needs about \(ByteFormat.short(model.approximateMemoryBytes)) of memory — "
                    + "heavy for this Mac's \(ByteFormat.short(manager.physicalMemory)).",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            }

            progressRow(for: model, state: state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func actionControls(
        for model: SpeechModelDescriptor,
        isInstalled: Bool,
        isActive: Bool,
        state: SpeechModelManager.DownloadState
    ) -> some View {
        if state.isActive {
            Button("Cancel") { manager.cancel(model) }
                .controlSize(.small)
        } else if isInstalled {
            HStack(spacing: 6) {
                if !isActive {
                    Button("Use") { settings.activeSpeechModelID = model.id }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                }
                if !(manager.installedModel(withID: model.id)?.isBundled ?? false) {
                    Button {
                        pendingRemoval = model
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .help("Delete this model from your Mac")
                }
            }
        } else {
            Button(manager.hasResumableDownload(model) ? "Resume" : "Download") {
                pendingDownload = model
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func progressRow(
        for model: SpeechModelDescriptor,
        state: SpeechModelManager.DownloadState
    ) -> some View {
        switch state {
        case .idle:
            EmptyView()

        case .waiting:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Starting…").font(.system(size: 10)).foregroundStyle(.secondary)
            }

        case .downloading(let fraction, let received, let total):
            VStack(alignment: .leading, spacing: 3) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                Text("\(ByteFormat.short(received)) of \(ByteFormat.short(total)) · \(Int(fraction * 100))%")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

        case .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Verifying integrity…").font(.system(size: 10)).foregroundStyle(.secondary)
            }

        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Installing…").font(.system(size: 10)).foregroundStyle(.secondary)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(manager.storageDirectory.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(manager.storageDirectory.path)

                Button("Reveal") {
                    // Create it first, so Reveal works before the first
                    // download rather than silently doing nothing.
                    try? FileManager.default.createDirectory(
                        at: manager.storageDirectory,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([manager.storageDirectory])
                }
                .controlSize(.small)
                .font(.system(size: 10))

                Spacer()

                Text("\(ByteFormat.short(manager.availableDiskSpace)) free")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            if let error = manager.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Spells out exactly what pressing Download will do, before it happens.
    private func downloadConsentMessage(for model: SpeechModelDescriptor) -> String {
        var lines = [
            "This model is stored locally on your Mac and used for speech recognition. "
            + "Your microphone audio is never uploaded.",
            "",
            "Download size: \(ByteFormat.short(model.sizeBytes))",
            "Memory while active: about \(ByteFormat.short(model.approximateMemoryBytes))",
            "Languages: \(model.languages.label)",
            "Saved to: \(manager.storageDirectory.path)",
        ]
        if manager.isMemoryHeavy(model) {
            lines.append("")
            lines.append(
                "This Mac has \(ByteFormat.short(manager.physicalMemory)) of memory. "
                + "This model may be slow or cause pressure here."
            )
        }
        return lines.joined(separator: "\n")
    }
}
