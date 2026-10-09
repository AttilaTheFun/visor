import SwiftUI
import VisorClient

/// The onboarding shipped: while there are no computers, how to run Visor
/// Server on one, reach it from anywhere, and add it. Not where the app has
/// an account: its sign-in brings the computers.
public struct DefaultOnboarding: VisorOnboarding {
    public init() {}

    public func isNeeded(_ store: VisorStore) -> Bool {
        store.servers.isEmpty && VisorAccounts.current == nil
    }

    public func view(_ store: VisorStore) -> AnyView { AnyView(DefaultOnboardingView()) }
}
