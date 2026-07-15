import Foundation

/// Single source of truth for the external help / setup URLs surfaced in the
/// first-run onboarding (onboarding for self-hosters).
///
/// HermesMobile is a client for a `hermes-agent` gateway you run yourself, with
/// the HermesMobile plugin installed (multi-client streaming + device pairing +
/// push). A new user installing from the public link has no gateway yet, so the
/// Welcome + manual-setup screens link here to explain what's needed and how to
/// get it. The destination is the project's public repository, whose README walks
/// through installing the gateway + plugin and pairing the app.
enum HelpLinks {
    /// "What is Hermes / how do I get a (mobile-capable) gateway?" — the entry
    /// point for a self-hoster with no gateway yet. Points at the public project
    /// repo's setup guide.
    static let setupGuide = URL(string: "https://github.com/ab0991-oss/hermes-ios")!
}
