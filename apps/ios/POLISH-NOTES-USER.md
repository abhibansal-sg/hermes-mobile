# User-reported polish/bug notes (feed into the cleanup pass)

Captured live from device walks (TestFlight build 12). These MUST be folded into
the next cleanup/hardening batch.

## P1 — Keyboard stays open when opening the drawer
When the keyboard is up and the user swipes to open the drawer, the keyboard does
NOT dismiss — it stays open and looks awkward.
- Fix: dismiss the keyboard (resign first responder) when the drawer opens — wire
  into the drawer-open path in RootView's CompactLayout (the drag/toggle that sets
  DrawerState.isOpen). A `.scrollDismissesKeyboard` won't cover the drawer-open
  gesture; do an explicit endEditing / focus resign on drawer open.
- File: Views/Shell/RootView.swift (CompactLayout drawer gesture + open()).

## P1 — Settings sheet auto-closes on FIRST open, works on second
Opening Settings (the gear → showingSettings sheet) the first time: it presents
then auto-dismisses on its own; opening again it stays and works normally.
- Hypothesis: a competing state change right after first present dismisses the
  sheet — likely the drawer's onNavigate/close firing as/after the sheet presents,
  or a SwiftUI "sheet presented from a view that is itself still settling"
  first-present race. Investigate the showingSettings binding + any onNavigate/
  drawer-close that runs when the gear is tapped.
- File: Views/Drawer/DrawerView.swift (showingSettings sheet + gear button +
  onNavigate interaction).

## (already being handled separately — do NOT duplicate)
- Chat scroll open-on-newest / scroll-to-bottom white void / keyboard-rises-
  transcript: deterministic rebuild in flight (native bottom-anchor).
