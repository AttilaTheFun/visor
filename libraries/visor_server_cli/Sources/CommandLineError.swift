/// What stops a command.
enum CommandLineError: Error {
    /// It was asked wrongly: said with the usage.
    case usage(String)
    /// It could not be done.
    case failed(String)
}
