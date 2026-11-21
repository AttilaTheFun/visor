// Settings' Sessions container section (docs/containers.md): its switch,
// and the readiness row under it — this Mac (macOS 26 or later, Apple
// silicon, virtualization), the Containers volume, and the assets on it.
// The switch is off, and can't be turned on, unless this Mac can run it.
// Read here, as files and this Mac's own facts: nothing is fetched (the
// container engine does that when it first starts).

import DiskVolumes
import Foundation
import SwiftUI
import VisorContainer
import VisorContainerCore
import VisorProtocol

@MainActor
struct ContainerSettingsSection: View {
    var settings: ServerControls.Settings
    var send: (ServerControlsChange) -> Void
    @State private var readiness: ContainerReadiness?
    @State private var image: ImageDigest?

    var body: some View {
        Section {
            let readiness = readiness ?? Self.look(override: settings.containerImageDigest).readiness
            Toggle("Run sessions in a container", isOn: Binding(get: { readiness.isEnabled(setting: settings.containerEnabled) },
                                                                set: { send(ServerControlsChange(containerEnabled: $0)) }))
                .disabled(!readiness.canEnable)
            ForEach(readiness.checks) { check in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: check.ok ? "checkmark.circle.fill" : "xmark.circle")
                        .foregroundColor(check.ok ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(check.name)
                        Text(check.detail).font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Text(imageLine)
                .font(.caption).foregroundColor(.secondary)
                .textSelection(.enabled)
        } header: {
            Text("Sessions Container")
        }
        .task(id: settings.containerImageDigest) {
            let look = Self.look(override: settings.containerImageDigest)
            readiness = look.readiness
            image = look.image
        }
    }

    private var imageLine: String {
        guard let image else { return "No agent image pinned: this build has no container.json, and the settings name no image digest." }
        let from = settings.containerImageDigest.isEmpty ? "this release's" : "the settings' (containerImageDigest)"
        return "Image \(image.reference()), \(from)."
    }

    /// This Mac's readiness, and the image it would run.
    static func look(override: String) -> (readiness: ContainerReadiness, image: ImageDigest?) {
        let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Visor")
        let volumes = DiskVolumes.locate(dataDirectory: data)
        let image = ContainerAssets.image(manifest: ContainerManifest.inResources(Bundle.main.resourceURL),
                                          override: override.isEmpty ? nil : override)
        let assets = (try? ContainerLayout.locate(volumes)).map {
            ContainerAssets(layout: $0, image: image, backend: ContainerizationBackend()).status()
        }
        return (ContainerReadiness(host: .current, volume: volumes.containers, assets: assets), image)
    }
}
