import SwiftUI
import VisorClient

/// What a new user is shown before the app is set up: how to get a computer
/// running Visor Server and reachable, and how to add it. The default one
/// (`DefaultOnboarding`) shows while there are no computers; a fork whose
/// setup is more involved (a company's front, its single sign-on, access to
/// ask for) registers its own at launch (`VisorOnboardings.current`) and
/// decides when it shows.
@MainActor
public protocol VisorOnboarding {
    /// Whether it is shown now, in place of the computers (and before the
    /// app's account's sign-in, where there is one).
    func isNeeded(_ store: VisorStore) -> Bool
    /// What it shows. The add sheet is the app's: setting
    /// `store.addingServer` opens it; `store.signInAccount()` signs the
    /// app's account in.
    func view(_ store: VisorStore) -> AnyView
}
