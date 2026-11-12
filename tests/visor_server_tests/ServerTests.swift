import Testing

/// Every suite of the server's tests is one of these: serialized, as the
/// tests set the server's process-wide state (its socket path, its secrets,
/// PATH and HOME) and a test of another suite running beside would see it.
@Suite(.serialized) enum ServerTests {}
