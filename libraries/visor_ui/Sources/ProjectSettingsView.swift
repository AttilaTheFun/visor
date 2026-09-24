// A project's settings, in the detail column: what Visor calls the
// folder, where it is on the computer, its archive, and the ways out —
// locate a folder that moved, or forget the project.

import SwiftUI
import VisorClient
import VisorProtocol

@MainActor
struct ProjectSettingsView: View {
    @ObservedObject var host: HostConnection
    let project: HostConnection.Project
    let rename: () -> Void
    let locate: () -> Void
    let archive: () -> Void
    let remove: () -> Void

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: project.name)
                LabeledContent("Folder", value: project.cwd)
                LabeledContent("Computer", value: host.config.name.isEmpty ? host.config.host : host.config.name)
            } header: {
                Text("Project")
            } footer: {
                if project.missing {
                    Text("\(host.config.name.isEmpty ? "The computer" : host.config.name) can no longer find this folder.")
                }
            }
            Section {
                Button("Rename in Visor…", action: rename)
                Button("Copy folder path") { copyToPasteboard(project.cwd) }
                if project.missing {
                    Button("Locate the folder…", action: locate)
                }
                if !project.archived.isEmpty {
                    Button("Archived Sessions (\(project.archived.count))", action: archive)
                }
            }
            Section {
                Button("Remove Project", role: .destructive, action: remove)
                    .disabled(!project.isEmpty && !project.missing)
            } footer: {
                Text(project.isEmpty || project.missing
                     ? "Visor forgets this folder and stops listing it. The folder and everything in it stay on the computer."
                     : "Archive or remove its \(project.sessions.count + project.archived.count) session\(project.sessions.count + project.archived.count == 1 ? "" : "s") first.")
            }
        }
        .insetGroupedForm()
        .navigationTitle(project.name)
    }
}
