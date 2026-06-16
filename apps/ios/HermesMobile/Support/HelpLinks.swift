import Foundation

/// Single source of truth for the external help / setup URLs surfaced in the
/// first-run onboarding (A1 — public-beta onboarding for self-hosters).
///
/// HermesMobile is useless without a `hermes-agent` gateway that runs the
/// **HermesMobile plugin** (multi-client streaming + device pairing + push;
/// see `dist/hermes-mobile/INSTALL.md`). A new user installing from the public
/// TestFlight link has no gateway yet, so the Welcome + manual-setup screens
/// link here to explain what's needed and how to get it.
///
/// ⚠️ PRE-PUBLIC-BETA PREREQUISITE: `setupGuide` must resolve to a PUBLICLY
/// reachable page that walks a self-hoster through installing Hermes **and** the
/// HermesMobile plugin. The plug-and-play installer currently lives only in the
/// private backup mirror (`ab0991-oss/hermes-mobile/dist/hermes-mobile/`), so a
/// stranger cannot reach it. Point this at the public install home before
/// turning on the public link — it is the ONE place to change.
enum HelpLinks {
    /// "What is Hermes / how do I get a (mobile-capable) gateway?" — the entry
    /// point for a self-hoster with no gateway yet. Default is the public
    /// hermes-agent site (gets the base gateway); replace with the page that
    /// also covers the HermesMobile plugin install before the public beta.
    static let setupGuide = URL(string: "https://hermes-agent.nousresearch.com")!
}
