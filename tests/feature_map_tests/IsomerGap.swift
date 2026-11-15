// Where Isomer's driver, headless and on Android and the web (Isomer's own
// runtime: drive/driver/IsomerAppDriver.swift), doesn't yet show what
// FEATURE_MAP.md names, so a test finds the element another way and says
// so as a known issue. Apple's driver reads the app's accessibility tree,
// where these hold; once Isomer's do too, the test takes the identifier
// and no known issue is recorded.

enum IsomerGap: String {
    /// `.accessibilityIdentifier` (and `.accessibilityLabel`) put on a
    /// control after a modifier that wraps it (`.padding()`, `.frame`,
    /// `.background`, as AgentUI's `agentPillButton()` does) lands on the
    /// wrapper, and the driver reads them only on the control's own node
    /// (IsomerAppDriver.walk's `p["a11yId"]`): Allow, Deny, Answer, the
    /// model's pill, Use a Connection Code Instead.
    case wrappedControl = "Isomer: an identifier after a wrapping modifier (.padding, .agentPillButton) is lost"

    /// A List row's content carries the identifier (`session-‹id›`,
    /// `message-hit`) and the row the List makes of it (its selection's
    /// `.tag`) takes the tap: the row button has no identifier.
    case listRow = "Isomer: a List(selection:) row's identifier, on its content, is not the row button's"

    /// A section header made one element (`.accessibilityElement(children:
    /// .combine)`) with an identifier (`computer-‹name›`) is no element: its
    /// texts are one text, with no identifier.
    case combinedElement = "Isomer: an .accessibilityElement(children: .combine) view with an identifier is not listed"

    /// A Toggle's identifier (`relay-toggle`, `settings-notify-‹kind›`).
    case toggle = "Isomer: a Toggle's identifier is not listed"

    /// A bottom bar's `Button("New session", systemImage:)` is labelled by
    /// its symbol ("✎"), not its title.
    case bottomBarTitle = "Isomer: a bottom bar Button(_:systemImage:) is labelled by its symbol, not its title"
}
