// What reading a secret found: the secret, nothing kept under its name, or
// a failure to read (the keychain refused, the file is unreadable or isn't
// JSON). Whoever would make a secret only when there is none (the signing
// keys) tells the last from the second, and never writes over a secret it
// couldn't read.

/// A secret looked up.
public enum SecretLookup: Equatable, Sendable {
    /// It, as kept.
    case found(String)
    /// Nothing is kept under its name.
    case absent
    /// It couldn't be read: why.
    case unreadable(String)
}
