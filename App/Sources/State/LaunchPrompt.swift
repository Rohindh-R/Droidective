import Foundation

/// Which first-run prompt (if any) to show on launch, in priority order.
///
/// Pure logic so the onboarding decision tree — five interacting persisted flags
/// across role picker → tour → privacy consent → GitHub-star nudge — is
/// unit-tested rather than only exercised by hand. `RootView` reads the flags and
/// drives the UI; this just decides which prompt is due.
enum LaunchPrompt: Equatable {
    /// Brand-new user picks a role; its dismissal chains into the tour.
    case rolePicker
    case tour
    case consent
    case star

    /// The highest-priority prompt due for the given persisted state, or nil.
    static func next(
        hasChosenRole: Bool,
        hasSeenTour: Bool,
        consentAsked: Bool,
        starPromptShown: Bool,
        launchCount: Int,
        askConsentOnFirstLaunch: Bool,
        consentAfterLaunches: Int,
        starAfterLaunches: Int
    ) -> LaunchPrompt? {
        if !hasChosenRole && !hasSeenTour { return .rolePicker }
        if !hasSeenTour { return .tour }
        if consentDue(
            consentAsked: consentAsked, launchCount: launchCount,
            askOnFirstLaunch: askConsentOnFirstLaunch, afterLaunches: consentAfterLaunches
        ) {
            return .consent
        }
        if starDue(starPromptShown: starPromptShown, launchCount: launchCount, afterLaunches: starAfterLaunches) {
            return .star
        }
        return nil
    }

    /// Whether the privacy disclosure is due (also consulted after the tour closes).
    static func consentDue(consentAsked: Bool, launchCount: Int, askOnFirstLaunch: Bool, afterLaunches: Int) -> Bool {
        guard !consentAsked else { return false }
        return askOnFirstLaunch || launchCount >= afterLaunches
    }

    /// Whether the one-time GitHub-star nudge is due.
    static func starDue(starPromptShown: Bool, launchCount: Int, afterLaunches: Int) -> Bool {
        !starPromptShown && launchCount >= afterLaunches
    }
}
