// Where Isomer's driver doesn't yet show what FEATURE_MAP.md names, so a
// test finds the element another way and says so as a known issue: headless
// and on Android and the web (Isomer's own runtime:
// drive/driver/IsomerAppDriver.swift), and on the iPhone (Apple's
// accessibility tree: drive/apple/UIKitAccessibility.swift). Once the
// driver shows it, the test takes the identifier and no known issue is
// recorded.

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

    /// On the iPhone, Isomer's Apple driver lists the identifier of a
    /// navigation bar's item and of a few controls (`settings`,
    /// `settings-appearance`), but not of a SwiftUI control in a List's or
    /// a Form's row, a text field, or the navigation title's button
    /// (`add-computer`, `runner`, `host`, `connect`, `session-title`,
    /// `allow`, `question-send`, …), which XCUITest reads
    /// (drive/apple/UIKitAccessibility.swift's visitObject reads
    /// `UIAccessibilityIdentification.accessibilityIdentifier`, which
    /// SwiftUI's elements leave empty there).
    case appleIdentifier = "Isomer (iOS): a SwiftUI control's identifier in a List or Form row, a text field's, the title's is not listed"

    /// On the iPhone, `dismiss` (drive/apple/UIKitAccessibility.swift's
    /// `dismiss`: the sheet's `accessibilityPerformEscape()`) doesn't close
    /// most of Visor's sheets (Add Computer, Tool calls, the attachment's
    /// preview, the question), which a swipe down or their Cancel or Done
    /// does: the test taps that.
    case appleDismiss = "Isomer (iOS): dismiss (accessibilityPerformEscape) doesn't close a SwiftUI sheet"

    /// On the iPhone on its side (the app turned by its own setting on an
    /// upright simulator, as the proof has it), a tap on a list's row
    /// "didn't take" (drive/apple/UIKitAccessibility.swift's `activate`),
    /// scrolled to or not; upright it does.
    case appleLandscapeTap = "Isomer (iOS): on its side, a tap on a list's row doesn't take"
}
