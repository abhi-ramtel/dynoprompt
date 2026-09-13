//
//  ScriptLibraryView.swift
//  DynoPrompt
//
//  The script library: create, open, rename and delete scripts that live on
//  this Mac only.
//
//  Presented as a sheet rather than a permanent sidebar. The editor window is
//  deliberately a single focused surface — adding a always-visible list would
//  work against the "get in, read, get out" flow the app is built around.
//

import SwiftUI

@Observable
final class ScriptLibraryModel {
    static let shared = ScriptLibraryModel()

    private(set) var scripts: [Script] = []
    private(set) var storageError: String?
    /// The library entry the editor is currently working on, if any.
    var activeScriptID: UUID?

    private var store: ScriptLibraryStore?

    init() {
        do {
            let directory = try ScriptLibraryStore.defaultDirectory()
            store = ScriptLibraryStore(directory: directory)
            reload()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func reload() {
        scripts = store?.loadAll() ?? []
    }

    /// Saves the given pages, either updating the active script or creating a
    /// new one. Returns the stored script.
    @discardableResult
    func save(pages: [String], title: String? = nil) -> Script? {
        guard let store else { return nil }

        var script: Script
        if let activeScriptID, var existing = scripts.first(where: { $0.id == activeScriptID }) {
            existing.pages = pages
            if let title { existing.title = title }
            script = existing
        } else {
            script = Script(
                title: title ?? Script.derivedTitle(fromPages: pages),
                pages: pages
            )
        }

        do {
            let saved = try store.save(script)
            activeScriptID = saved.id
            reload()
            storageError = nil
            return saved
        } catch {
            storageError = error.localizedDescription
            return nil
        }
    }

    func rename(_ script: Script, to title: String) {
        guard let store else { return }
        var updated = script
        updated.title = title
        do {
            _ = try store.save(updated)
            reload()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func delete(_ script: Script) {
        guard let store else { return }
        do {
            try store.delete(id: script.id)
            if activeScriptID == script.id { activeScriptID = nil }
            reload()
        } catch {
            storageError = error.localizedDescription
        }
    }

    func duplicate(_ script: Script) {
        guard let store else { return }
        let copy = Script(title: "\(script.title) copy", pages: script.pages)
        do {
            _ = try store.save(copy)
            reload()
        } catch {
            storageError = error.localizedDescription
        }
    }
}

struct ScriptLibraryView: View {
    @Environment(\.dismiss) private var dismiss

    var model: ScriptLibraryModel
    /// Called when the user picks a script to load into the editor.
    var onOpen: (Script) -> Void
    /// Called when the user asks for a blank script.
    var onNew: () -> Void

    @State private var selection: UUID?
    @State private var renamingID: UUID?
    @State private var renameText: String = ""
    @State private var pendingDeletion: Script?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.scripts.isEmpty {
                emptyState
            } else {
                list
            }

            Divider()
            footer
        }
        .frame(width: 460, height: 420)
        .alert(
            "Delete this script?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { script in
            Button("Delete", role: .destructive) {
                model.delete(script)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { script in
            Text("“\(script.title)” will be removed from this Mac. This can't be undone.")
        }
    }

    private var header: some View {
        HStack {
            Text("Scripts")
                .font(.system(size: 15, weight: .semibold))
            Spacer()
            Button {
                onNew()
                dismiss()
            } label: {
                Label("New", systemImage: "plus")
            }
            .controlSize(.small)
            .help("Create a new empty script")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No saved scripts yet")
                .font(.system(size: 13, weight: .medium))
            Text("Scripts you save stay on this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(model.scripts) { script in
                row(for: script)
                    .tag(script.id)
                    .contextMenu {
                        Button("Open") { open(script) }
                        Button("Rename") { beginRename(script) }
                        Button("Duplicate") { model.duplicate(script) }
                        Divider()
                        Button("Delete", role: .destructive) { pendingDeletion = script }
                    }
            }
        }
        .listStyle(.inset)
    }

    private func row(for script: Script) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                if renamingID == script.id {
                    TextField("Name", text: $renameText, onCommit: { commitRename(script) })
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                } else {
                    Text(script.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                Text(subtitle(for: script))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.activeScriptID == script.id {
                Text("Open")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(script) }
    }

    private func subtitle(for script: Script) -> String {
        let minutes = max(1, Int((script.estimatedDuration / 60).rounded()))
        let pages = script.pages.count > 1 ? " · \(script.pages.count) pages" : ""
        return "\(script.wordCount) words · ~\(minutes) min\(pages) · "
            + Self.dateFormatter.string(from: script.updatedAt)
    }

    private var footer: some View {
        HStack {
            if let error = model.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                Text("Stored locally in Application Support")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Open") {
                if let selection, let script = model.scripts.first(where: { $0.id == selection }) {
                    open(script)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func open(_ script: Script) {
        onOpen(script)
        dismiss()
    }

    private func beginRename(_ script: Script) {
        renameText = script.title
        renamingID = script.id
    }

    private func commitRename(_ script: Script) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            model.rename(script, to: trimmed)
        }
        renamingID = nil
    }
}
