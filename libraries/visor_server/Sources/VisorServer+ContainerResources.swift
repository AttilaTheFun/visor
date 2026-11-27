// The Sessions container's CPUs, memory cap and idle minutes as `PUT
// /api/settings` changes them (docs/containers.md, Settings): each within
// this computer's, or the change refused with why (never clamped), `null`
// or `"default"` back to its default, kept in ServerSettings.container.
// The CPUs and memory are taken at the container's next start: a running
// VM isn't resized, and the server never restarts it for them, so its
// sessions go on. The idle minutes are taken at once (the idle stop reads
// them each time it looks).

import VisorProtocol

extension VisorServer {
    /// When a change takes effect, as `containerLimits.note` says it.
    static let containerResourcesNote = "CPUs and memory are taken at the container's next start: after its idle stop, a Stop and Start, "
        + "or Visor's restart. A running container isn't restarted for them. Idle minutes are taken at once."

    /// What the container's CPUs, memory and idle minutes may be set to on
    /// this computer, and their defaults.
    var containerLimits: ServerControls.ContainerLimits {
        let host = hostResources()
        return ServerControls.ContainerLimits(
            minimumCPUs: ContainerSettings.minimumCPUs, maximumCPUs: ContainerSettings.maximumCPUs(cores: host.cores),
            defaultCPUs: ContainerSettings.defaultCPUs(cores: host.cores), minimumMemoryGiB: ContainerSettings.minimumMemoryGiB,
            maximumMemoryGiB: max(ContainerSettings.maximumMemoryGiB(physicalBytes: host.memoryBytes), 0),
            defaultMemoryCapGiB: ContainerSettings.defaultMemoryCapGiB, minimumIdleMinutes: ContainerSettings.idleMinutesRange.lowerBound,
            maximumIdleMinutes: ContainerSettings.idleMinutesRange.upperBound, defaultIdleMinutes: ContainerSettings.defaultIdleMinutes,
            note: Self.containerResourcesNote)
    }

    /// `change`'s CPUs, memory and idle minutes set in `container`; why
    /// not when one can't be, and `container` left as it was.
    func applyContainerResources(_ change: ServerControlsChange, to container: inout ContainerSettings) -> String? {
        let host = hostResources()
        var next = container
        switch change.containerCPUs {
        case nil: break
        case .byDefault: next.cpus = nil
        case .to(let cpus):
            if let problem = ContainerSettings.refusal(cpus: cpus, cores: host.cores) { return problem }
            next.cpus = cpus
        case .unreadable(let value): return "containerCPUs is a whole number, or null for the default, not \(value.encoded())."
        }
        switch change.containerMemoryGiB {
        case nil: break
        case .byDefault: next.memoryGiB = nil
        case .to(let gib):
            if let problem = ContainerSettings.refusal(memoryGiB: gib, physicalBytes: host.memoryBytes) { return problem }
            next.memoryGiB = gib
        case .unreadable(let value): return "containerMemoryGiB is a whole number of GiB, or null for the default, not \(value.encoded())."
        }
        switch change.containerIdleMinutes {
        case nil: break
        case .byDefault: next.idleMinutes = ContainerSettings.defaultIdleMinutes
        case .to(let minutes):
            if let problem = ContainerSettings.refusal(idleMinutes: minutes) { return problem }
            next.idleMinutes = minutes
        case .unreadable(let value): return "containerIdleMinutes is a whole number, or null for the default, not \(value.encoded())."
        }
        if next.cpus != container.cpus || next.memoryGiB != container.memoryGiB {
            let cpus = next.cpus.map { "\($0)" } ?? "the default"
            let memory = next.memoryGiB.map { "\($0) GiB" } ?? "the default"
            Self.log("the Sessions container's CPUs are \(cpus), its memory \(memory): taken at its next start")
        }
        container = next
        return nil
    }
}
