/// Somewhere outside the app that shows the latest sessions: the home
/// screen's widget on iOS. Given the latest as JSON whenever it changes; a
/// host without one installs none.
@MainActor
public protocol VisorWidgetService {
    func publish(_ json: String)
}
