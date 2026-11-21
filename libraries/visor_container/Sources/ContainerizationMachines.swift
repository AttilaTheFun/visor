// The container engine's VM on a Mac (ContainerBackend), on Apple's
// Containerization (a port of Shireworks' ContainerHelper.boot): the
// kernel, the init filesystem read-only as the VM's `/`, the root
// filesystem as the container's, a VM of the CPUs and memory asked (its
// guest's overhead on top), no network interface, the folders shared in over
// virtiofs, the relay's socket carried in, and the main process (with
// Containerization's init, so signals are forwarded and zombies reaped) in
// the image's environment, as root. Needs the virtualization entitlement and
// a Mac that can make VMs.

import Containerization
import ContainerizationOCI
import Foundation
import VisorContainerCore

public struct ContainerizationMachines: ContainerBackend {
    /// The same image store's reader that fetched the assets.
    private let images: ContainerizationBackend

    public init(images: ContainerizationBackend) {
        self.images = images
    }

    public func boot(_ spec: ContainerBootSpec) async throws -> any ContainerMachine {
        let vmm = VZVirtualMachineManager(kernel: Kernel(path: spec.kernel, platform: .linuxArm),
                                          initialFilesystem: .block(format: "ext4", source: spec.initfs.path, destination: "/", options: ["ro"]))
        var config = LinuxContainer.Configuration()
        if let image = try await images.imageConfig(spec.image, store: spec.store) {
            config.process = LinuxProcessConfiguration(from: image)
        }
        // relay-client sets the guest's network up (netlink, nftables): root.
        config.process.user = ContainerizationOCI.User()
        config.process.arguments = spec.arguments
        let main = try LogWriter(spec.mainLog)
        config.process.stdout = main
        config.process.stderr = main
        // No network: no interface, no address. Its one way out is the relay.
        config.interfaces = []
        config.sockets = spec.sockets.map {
            UnixSocketConfiguration(source: URL(fileURLWithPath: $0.host), destination: URL(fileURLWithPath: $0.guest), direction: .into)
        }
        for share in spec.shares {
            config.mounts.append(.share(source: share.source, destination: share.destination, options: share.readOnly ? ["ro"] : []))
        }
        config.cpus = spec.cpus
        config.memoryInBytes = spec.memoryBytes
        config.hostname = spec.name
        config.useInit = true
        config.bootLog = .file(path: spec.bootLog, append: false)
        let container = try LinuxContainer(spec.name, rootfs: .block(format: "ext4", source: spec.rootfs.path, destination: "/"), vmm: vmm,
                                           vm: VMResources(cpus: spec.cpus, memoryInBytes: spec.memoryBytes + VMResources.guestMemoryOverhead),
                                           configuration: config)
        try await container.create()
        do {
            try await container.start()
        } catch {
            try? await container.stop()
            throw error
        }
        return ContainerizationMachine(container: container, base: config.process)
    }
}
