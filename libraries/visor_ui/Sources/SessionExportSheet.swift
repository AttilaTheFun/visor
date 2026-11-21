// A session exported as a session archive (SessionExport), from the
// session's menu or the Mac's File › Export…: the computer writes it and
// this device reads it, with its progress; then it is saved where the
// person chooses (the Mac's save panel, opened at once) or, on the iPhone,
// shared. The session stays as it is.

import Foundation
import SwiftUI
import VisorClient
import VisorServices
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

@MainActor
struct SessionExportSheet: View {
    let export: SessionExport
    @Environment(\.dismiss) private var dismiss
    /// The save panel (the file exporter) is open.
    @State private var saving = false
    /// Where it was saved, or why not.
    @State private var said: String?

    var body: some View {
        NavigationStack {
            Form { content }
                .insetGroupedForm()
                .navigationTitle("Export “\(export.session.title)”")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(export.phase == .exporting ? "Cancel" : "Done") { dismiss() }
                            .accessibilityIdentifier("export-done")
                    }
                }
        }
        .presentationDetentsMediumLarge()
        .task {
            guard export.phase == .exporting, export.progress == 0 else { return }
            await export.run()
            if case .ready = export.phase, Compat.savesExportAtOnce, VisorHost.savesFiles { saving = true }
        }
        .fileExporter(isPresented: $saving, document: document, contentType: .visorSession, defaultFilename: export.name) { result in
            switch result {
            case .success(let url): said = "Saved to \(url.path)."
            case .failure(let error): said = "Not saved: \(error.localizedDescription)"
            }
        }
    }

    /// The archive to save, once it is here.
    private var document: SessionArchiveDocument? {
        if case .ready(let url) = export.phase { return SessionArchiveDocument(url: url) }
        return nil
    }

    @ViewBuilder private var content: some View {
        switch export.phase {
        case .exporting:
            Section {
                ProgressView(value: export.progress) {
                    Text(export.size == 0 ? "Writing the archive on \(export.host.record.name)…" : "Reading \(export.name)…")
                }
                .accessibilityIdentifier("export-progress")
            }
        case .ready(let url):
            Section {
                LabeledContent("File", value: export.name)
                LabeledContent("Size", value: MigrationSheet.size(export.size))
                // Shared alone where the host saves no file (Visor Client's
                // sandbox reads the files picked and writes none).
                if VisorHost.savesFiles {
                    Button("Save…") { saving = true }
                        .accessibilityIdentifier("export-save")
                }
                shareFileLink(url)
                if let said {
                    Text(said).font(.footnote).accessibilityIdentifier("export-said")
                }
            } footer: {
                Text("The session's conversation, the folder beside it and Claude's memory, in one file. Import it on any computer "
                     + "with File › Import… or New Session › Restore. The session here stays as it is; projects don't come.")
            }
        case .failed(let problem):
            Section {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("export-error")
            } header: {
                Text("Not exported")
            }
        }
    }
}
