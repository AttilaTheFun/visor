/// Speech into a message, where the host has a microphone and a speech
/// recognizer (a phone, a Mac): started by the composer's microphone
/// button, the words heard so far handed back as they come, stopped by
/// the same button. A host without it (a TV, where the remote's own
/// dictation types into the system keyboard; the web) installs none,
/// and the composer shows no microphone.
@MainActor
public protocol VisorDictationService: AnyObject {
    /// Starts listening. `heard` is called, on the main actor, with
    /// everything heard since the start, each time more comes. Throws
    /// when the system refuses (no permission, no microphone, no
    /// recognizer for the language).
    func start(heard: @escaping @MainActor @Sendable (String) -> Void) async throws
    /// Stops listening. What was heard stays where `heard` put it.
    func stop()
}
