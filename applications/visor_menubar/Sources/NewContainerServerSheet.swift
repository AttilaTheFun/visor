import SwiftUI
import UniformTypeIdentifiers

/// A new container server: its name, image and port, the networks that
/// reach it, and the folder of this Mac's seen in it.
struct NewContainerServerSheet: View {
    var servers: RunnerContainerServers
    var defaultImage: String
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var image = ""
    @State private var port = 7440
    @State private var lan = true
    @State private var vpn = true
    @State private var folder = ""
    @State private var choosing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $name)
                TextField("Image", text: $image)
                TextField("Port", value: $port, format: .number.grouping(.never))
                Toggle("Reachable on the local network", isOn: $lan)
                Toggle("Reachable on VPNs", isOn: $vpn)
                HStack {
                    TextField("Folder seen inside", text: $folder)
                    Button("Choose…") { choosing = true }
                }
                Text("The folder is seen in the container at the same path, so a project in it moves between this Mac's server and the container's without being copied. The port after the server's is the one its agents reach their MCP servers through.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Make") {
                    servers.make(name: name.trimmingCharacters(in: .whitespaces), image: image.trimmingCharacters(in: .whitespaces),
                                 port: port, lan: lan, vpn: vpn, folder: folder.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || image.trimmingCharacters(in: .whitespaces).isEmpty
                          || !(1024...65534).contains(port))
            }
            .padding()
        }
        .frame(width: 460)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if let url = try? result.get() { folder = url.path }
        }
        .onAppear {
            image = defaultImage
            port = servers.nextPort
            let developer = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer").path
            folder = FileManager.default.fileExists(atPath: developer) ? developer : ""
        }
    }
}
