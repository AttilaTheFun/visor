extension CodexOutput {
    /// An output with the thread the app server said it is of, if it said.
    struct Heard: Sendable {
        let thread: String?
        let output: CodexOutput
    }
}
