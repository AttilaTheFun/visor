// Picking a folder on the host for a new project: the subfolders of the
// current one, a row to go up, a row to make a new folder (created with its
// parents when chosen), and the path itself editable at the top.

import NavigationUI
import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct FolderPicker: View {
    @ObservedObject var host: HostConnection
    /// Where it opens: the folder chosen now, or home.
    var start: String = "~"
    let chosen: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var path = "~"
    @State private var folders: [String] = []
    @State private var loading = false
    @State private var error: String?
    @State private var newFolder = ""
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Path", text: $path)
                        .autocorrectionDisabled()
                        .keyboardTypeURL()
                        .onSubmit { load() }
                        .accessibilityIdentifier("folder-path")
                } footer: {
                    if let error { Text(error).foregroundColor(.red) }
                }
                Section {
                    if path != "/" {
                        Button {
                            path = parent(of: path)
                            load()
                        } label: {
                            Label("Up", systemImage: "arrow.up").rowLabel()
                        }
                        .buttonStyle(.plain)
                    }
                    if loading && folders.isEmpty {
                        HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundColor(.secondary) }
                    }
                    ForEach(folders, id: \.self) { name in
                        Button {
                            path = join(path, name)
                            load()
                        } label: {
                            Label(name, systemImage: "folder").rowLabel()
                        }
                        .buttonStyle(.plain)
                    }
                    if creating {
                        HStack {
                            Image(systemName: "folder.badge.plus").foregroundColor(.accentColor)
                            TextField("Folder name", text: $newFolder)
                                .autocorrectionDisabled()
                                .onSubmit(createFolder)
                            Button("Create", action: createFolder).disabled(newFolder.trimmed.isEmpty)
                        }
                    } else {
                        Button { creating = true } label: {
                            Label("New Folder…", systemImage: "folder.badge.plus").rowLabel()
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                    }
                } header: {
                    Text(path)
                }
            }
            .navigationTitle("Choose a folder")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Choose", action: choose)
                        .disabled(path.trimmed.isEmpty)
                        .accessibilityIdentifier("choose-folder")
                }
            }
        }
        .presentationDetentsMediumLarge()
        .onAppear {
            if !start.isEmpty { path = start }
            load()
        }
    }

    private func load() {
        loading = true
        error = nil
        let wanted = path.trimmed.isEmpty ? "~" : path.trimmed
        Task {
            do {
                let listing = try await host.folders(at: wanted)
                path = listing.path
                folders = listing.folders
            } catch {
                self.error = "\(error)"
            }
            loading = false
        }
    }

    /// A new folder inside the current one: made on the host at once.
    private func createFolder() {
        let name = newFolder.trimmed
        guard !name.isEmpty else { return }
        Task {
            do {
                path = try await host.makeFolder(join(path, name))
                newFolder = ""
                creating = false
                load()
            } catch {
                self.error = "\(error)"
            }
        }
    }

    /// The typed path is created (with its parents) if it does not exist yet.
    private func choose() {
        let wanted = path.trimmed
        Task {
            do {
                let resolved = try await host.makeFolder(wanted)
                dismiss()
                chosen(resolved)
            } catch {
                self.error = "\(error)"
            }
        }
    }

    private func parent(of path: String) -> String {
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        guard let slash = trimmed.lastIndex(of: "/") else { return "/" }
        let up = String(trimmed[..<slash])
        return up.isEmpty ? "/" : up
    }

    private func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }
}
