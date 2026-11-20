/// What stops a command.
public enum CommandLineError: Error {
    /// It was asked wrongly: said with the usage.
    case usage(String)
    /// It could not be done.
    case failed(String)
}
