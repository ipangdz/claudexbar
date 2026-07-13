# Codex Optional 5-Hour Window Design

## Goal

Keep Codex usage readable when OpenAI temporarily omits the 5-hour limit window. The missing slot must render only an em dash (`—`) while the weekly limit remains usable, and the normal 5-hour display must return automatically when the API provides it again.

## Observed API Change

ClaudexBar currently assumes `rate_limit.primary_window` is the 5-hour window and `rate_limit.secondary_window` is the weekly window. The live Codex response instead currently places a 604800-second weekly window in `primary_window` and returns `null` for `secondary_window`. Requiring both fields causes the entire otherwise-valid response to fail parsing.

## Data Model and Parsing

`UsageSnapshot.primary` and `UsageSnapshot.secondary` will become optional windows. For Codex, parsing will classify each non-null API window using `limit_window_seconds` when that field is present rather than assuming its `primary_window` or `secondary_window` position:

- 18000 seconds maps to the 5-hour slot.
- 604800 seconds maps to the weekly slot.
- Historical responses that omit `limit_window_seconds` remain supported when both windows exist: `primary_window` maps to 5 hours and `secondary_window` maps to weekly, matching the previously valid API shape.
- A missing 5-hour window maps to `nil` without producing a decoding error.
- A later response containing the 5-hour window maps it normally on the next refresh.

The response remains a decoding error when no recognized usage window can be recovered. Claude behavior remains unchanged except that its existing windows are wrapped in the optional snapshot representation.

## Rendering

The status pill preserves both column positions. When the 5-hour slot is unavailable, the entire left slot contains only `—`: no label, percentage, status word, tooltip, icon, emoji, or unlimited symbol. The weekly slot continues to render its real countdown/percentage.

The provider menu hint uses the same semantics, for example `— · 70%`. When both windows are present, rendering is unchanged.

## Notifications and Smart Switching

Notification evaluation, recovery tracking, cross-provider hints, and usage-delta tracking will skip unavailable windows. A missing window is not interpreted as 0%, 100%, depleted, recovered, or unlimited, so it cannot create false notifications or influence automatic provider selection.

Real authentication, network, rate-limit, server, or irrecoverably malformed-response failures retain their existing status behavior. Only a recognized missing limit window is treated as normal partial data.

## Verification

Add regression coverage for:

- A Codex response containing both 5-hour and weekly windows.
- A Codex response containing the weekly window in `primary_window` with `secondary_window: null`.
- Automatic restoration when a later response contains both windows again.
- Menu/display formatting of a missing 5-hour slot as only `—`.
- Notification and usage-delta logic ignoring unavailable windows.
- Existing Claude parsing and the full test runner remaining green.

No unrelated UI, provider-selection, authentication, release-version, install, or deployment changes are included.
