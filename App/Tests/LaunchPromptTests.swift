import Testing

/// The launch-prompt decision tree (role → tour → consent → star) is the kind of
/// multi-flag onboarding logic the audit flagged as bug-prone and untested.
@Suite struct LaunchPromptTests {
    /// Defaults represent a fully-onboarded user (nothing due); each test flips
    /// only the inputs it cares about. Thresholds mirror RootView's.
    private func next(
        hasChosenRole: Bool = true, hasSeenTour: Bool = true,
        consentAsked: Bool = true, starPromptShown: Bool = true,
        launchCount: Int = 0, askConsentOnFirstLaunch: Bool = false,
        consentAfterLaunches: Int = 5, starAfterLaunches: Int = 10
    ) -> LaunchPrompt? {
        LaunchPrompt.next(
            hasChosenRole: hasChosenRole, hasSeenTour: hasSeenTour,
            consentAsked: consentAsked, starPromptShown: starPromptShown,
            launchCount: launchCount, askConsentOnFirstLaunch: askConsentOnFirstLaunch,
            consentAfterLaunches: consentAfterLaunches, starAfterLaunches: starAfterLaunches)
    }

    @Test func brandNewUserGetsRolePicker() {
        #expect(next(hasChosenRole: false, hasSeenTour: false) == .rolePicker)
    }

    @Test func roleChosenButTourUnseenGetsTour() {
        #expect(next(hasChosenRole: true, hasSeenTour: false) == .tour)
    }

    @Test func tourTakesPriorityOverDueConsent() {
        #expect(next(hasSeenTour: false, consentAsked: false, launchCount: 50) == .tour)
    }

    @Test func consentIsDeferredUntilThreshold() {
        #expect(next(consentAsked: false, launchCount: 4) == nil)
        #expect(next(consentAsked: false, launchCount: 5) == .consent)
    }

    @Test func firstLaunchToggleSurfacesConsentImmediately() {
        #expect(next(consentAsked: false, launchCount: 0, askConsentOnFirstLaunch: true) == .consent)
    }

    @Test func consentTakesPriorityOverStar() {
        #expect(next(consentAsked: false, starPromptShown: false, launchCount: 20) == .consent)
    }

    @Test func starNudgeShownOnlyAtItsThresholdAfterConsent() {
        #expect(next(consentAsked: true, starPromptShown: false, launchCount: 9) == nil)
        #expect(next(consentAsked: true, starPromptShown: false, launchCount: 10) == .star)
    }

    @Test func fullyOnboardedUserSeesNothing() {
        #expect(next(launchCount: 100) == nil)
    }
}
