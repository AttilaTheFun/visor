import VisorClient

/// The app's onboarding: the default one, unless a fork sets its own at
/// launch.
@MainActor
public enum VisorOnboardings {
    public static var current: any VisorOnboarding = DefaultOnboarding()
}
