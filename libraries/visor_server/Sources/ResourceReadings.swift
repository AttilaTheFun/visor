/// The last reading of this computer's processors and of each container's,
/// kept for the next: a share of processor time is the difference between
/// two.
struct ResourceReadings {
    var host: (sample: HostLoadSample, at: ContinuousClock.Instant)?
    var containers: [String: (cpuMicroseconds: UInt64, at: ContinuousClock.Instant)] = [:]
    /// When the containers were last read (none running is a reading too).
    var containersAt: ContinuousClock.Instant?
}
