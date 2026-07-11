# Hermes Mobile — Design System

The design direction for Hermes Mobile (iOS). Three files, one system:

| file | role | who reads it |
|------|------|--------------|
| **DESIGN.md** | Normative token spec (Google DESIGN.md format). Color roles, type scale, spacing, radius, components. Machine-readable front matter + rationale. Lints clean (`npx @google/design.md lint`). | engineers building UI; tooling |
| **DESIGN-SYSTEM.md** | Prose doctrine. The one law, the six-theme matrix, component inventory vs the current app, the Liquid Glass adoption map, state patterns, density & motion. | anyone shaping a surface |
| **GATE-RUBRIC.md** | The 9-dimension checklist the design gate applies to UI PRs. Every verdict cites a spec section, never bare taste. | the designer seat at review |
| **TRANSCRIPT-CHROME-TOKENS.md** | Motion + box tokens for the STR-989 clean-chrome cluster (extends DESIGN.md). The single source T-2/T-3/T-4 compile against: pulse-glow, status-glow, fade-mask, the canonical box/diff look, thinking-block chrome. Desktop-parity, source-cited. | engineers building transcript chrome; the gate |

## The one law

> **Glass for chrome. Themes for content. Accent for identity.**

System renders chrome as Liquid Glass (iOS 26+) / painted fallback (17–25);
the `HermesTheme` palette owns content; a single accent (`midground`) carries
identity across six themes. This is not a redesign — it codifies direction that
already shipped through CONTRACT-UI-{A..I} and bends new work toward the native
material system.

## Source of truth

Tokens live in code: `apps/ios/HermesMobile/Theme/`. This spec documents and
governs them; it does not replace them. When code and spec drift, the gate flags
it and one of the two is patched.

## Provenance

STR-308 (DESIGN COMMISSION #1). Audit + visual grounding from STR-244/75/142
perception evidence; direction lineage from `apps/ios/VISION.md`,
`CONTRACT-UI-*`, and `docs/PERCEPTION-QA.md`.
