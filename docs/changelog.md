# Changelog

## Unreleased

- Retry failed quota and account-history fetches up to five times with 1, 2, 4, 8 and 16 second exponential backoff; stop on success, cancellation or stale account requests. Retry temporary web analytics failures before retaining Codex history.
- Make every disclosure header clickable across its full row, including blank space, for usage windows, account history, daily details and settings.

- Reorganized app lifecycle, presentation models, views, core domains, CLI commands, resources and tests by responsibility.
- Rebuilt the Chinese-first README and development guide; centralized offline test execution and added portable source exports with checksum and one-commit Git validation.

- Renamed the project and macOS app to QuotaBar, with `quota-bar` as the repository slug and command name.
- Updated Swift modules, installation and release scripts, package filenames, documentation and issue links.
- Preserved the installed app identity, preferences, account profiles and quota-history paths; the installer also replaces an existing Codex Meter app.

## 1.7.5 — 2026-11-03

- Request ChatGPT daily usage through the reference extension's `daily-workspace-usage-counts` API, using tomorrow as the end date to include today.
- Obtain a short-lived token from the selected Codex app-server's compatibility `getAuthStatus` method; retain Codex history if authentication, the web API or today's absolute count is unavailable.
- Label web daily history as Work and Codex usage, replace the daily series together to preserve its scope, and keep Codex lifetime statistics separate. Preserve explicit zero, missing data and exact 64-bit counters.
- Cover web requests, local-midnight/DST boundaries, parsing, scope, authentication failures and stopped sessions with offline checks.

## 1.7.4 — 2026-10-20

- Standardized account usage units to M and B, with comma separators every three digits in charts, readouts, daily details, cumulative statistics and menu-bar history tooltips.
- Unified summary/axis formatting, kept exact 64-bit counts intact and handled the rounded M-to-B boundary without scientific notation.

## 1.7.3 — 2026-10-20

- Changed settings to flow with the main scroll document: they sit at the visible bottom for short content and follow overflowing content below the viewport.
- Removed the separate settings scroller and retained safe, expansion-driven popover sizing.
- Updated macOS layout checks to verify that settings scroll into view with long content, stay low with short content and share one scrollbar when expanded.

## 1.7.2 — 2026-10-20

- Added hover, click and drag inspection to daily usage charts, with persistent day selection and exact token readouts.
- Replaced scientific axis labels with millions (兆 in Chinese) and four complete month/day labels, preserving missing days and explicit zero usage.
- Made account usage history collapsible and hid the redundant period-picker label.
- Pinned settings outside the history scroll area, bounded expanded settings to their own scroll region and compacted the popover when all sections are collapsed.
- Added chart-formatting/date-selection checks and macOS tests for pinned settings and expansion-driven popover resizing.

## 1.7.1 — 2026-10-20

- Fixed popovers showing only the header by removing content-height feedback and setting an explicit, screen-bounded viewport before presentation.
- Kept daily details and settings scrollable without resizing the viewport; clock updates now refresh state without a TimelineView inside the scroll document.
- Added macOS layout checks for first opening, reopening, empty/populated data, smaller screens and scrolling to the end of expanded content.

## 1.7.0 — 2026-10-20

- Automatically publish verified main-branch builds to GitHub Releases, including manual main builds, with permanent ZIP/checksum downloads, exact source tags and a latest-release link.
- Limit release write permission to the main-only publish job, retain temporary artifacts for other builds, and publish only after both assets are uploaded successfully.

- Merged daily analytics into the existing account history section, with one default chart and a collapsed disclosure for daily details, period summaries, lifetime totals and recent quota changes; removed the separate Analytics tab and quota chart.
- Bounded expanded popover content to the screen height, refreshed displayed countdowns/pace on the clock and aligned the menu-bar history with account daily token usage.
- Decoupled quota and daily-history polling, refreshed both concurrently after wake/manual refresh and marked stale history visibly.
- Stopped showing expired-cycle percentages or weekly pace as current, suppressed expired-cycle low-quota alerts and hardened numeric parsing/countdown arithmetic.
- Stopped pending profile logins before deletion, ignored stale completion callbacks, restored a valid active profile after failed sign-in and fixed notification-delivery and banner-dismissal bookkeeping.

- Added account-wide daily token analytics from `account/usage/read`, with 7-day/30-day views, daily details, date lookup, usage sorting and an active-days filter.
- Kept missing days distinct from zero use, separated lifetime statistics from period totals, and isolated analytics errors and pending results during account switches.

- Replaced the app’s local-token activity panel with account-wide remaining-quota history, credit balance and available reset counts, polled every two minutes.
- Persisted isolated account snapshots across restarts and recorded net decreases with their original observation intervals.
- Marked gaps, new quota cycles, replenishment and changed allowances without inventing cross-reset usage; kept missing fields unavailable.
- Retained scheduled reset times, displayed new-cycle used percentages, and paused interval calculations while expired quota windows await a backend update.
- Updated the menu-bar chart to server-provided daily account token usage and kept optional CLI local-token history independent.
- Added offline regression checks for persistence, downtime, reset boundaries, account isolation and storage failures.

## 1.6.2 — 2026-10-11

- Fixed the false “Codex is not installed” error for desktop builds that moved their bundled service into `Contents/Resources/codex-cli/`; support the packaged launcher, nested native executable and legacy layout without a separate CLI installation.
- Added a “Select Codex App…” recovery action for installations outside standard locations, persisted the selected app and refreshed desktop discovery when retrying a missing service.
- Clarified the service-not-found message and included searched paths in sanitized diagnostics.
- Added new-layout fixtures and real process handshake checks through a desktop bundle and its packaged launcher.

## 1.6.1 — 2026-10-11

- Fixed quota bucket selection when modern servers return multiple limit IDs without a `codex` key; use the server’s canonical quota instead of an arbitrary product bucket.
- Find the current or registered desktop application, including renamed apps and user installations; prefer the unified ChatGPT desktop, verify its Codex bundle identity, and support absolute PATH locations.
- Report actual quota window durations, reject failed initialization, and protect replacement clients from callbacks belonging to older processes.
- Keep operation errors separate from quota failures, protect account switches against old refresh results, and prevent notification permission prompts from blocking polling.
- Refresh stale menu-bar state regularly and retry after wake; retain bounded, redacted process diagnostics and empty-response diagnostics for troubleshooting.
- Added official-protocol fixtures, executable discovery checks, initialization/reconnection checks and diagnostic privacy checks.

## 1.6.0 — 2026-10-10

- Added an original macOS application icon, generated as ICNS with native system tools at all standard and Retina sizes; included PNG and ICO source assets.
- Added English and Simplified Chinese interfaces with system language detection, a persistent Settings language selector and immediate UI refresh.
- Localized usage charts, settings, account dialogs, notifications, accessibility labels, dates and common errors; kept CLI output and JSON labels stable in English.
- Added localization regression checks and verified icon and language resources in the final release package.
- Updated installation instructions for current macOS Gatekeeper prompts.

## 1.5.0 — 2026-07-15

- Moved the named account switcher beside refresh with an explicit down-arrow affordance.
- Added a confirmation choice for Meter-only or Meter plus Codex desktop switching.
- Implemented desktop switching with OpenAI's documented app-server logout, secure browser login, account verification and relaunch flow.
- Fixed Codex opening with the supported settings deep link plus bundle-ID and application-path fallbacks.
- Fixed deletion for stale account records whose local profile directory is already missing.
- Added visible banked-reset counts from OpenAI's authoritative `rateLimitResetCredits.availableCount` field, with an honest unavailable state.
- Added live account-read, reset-history and profile-deletion validation.

## 1.4.0 — 2026-07-15

- Added confirmed deletion of unused local account profiles and their Codex-owned credentials.
- Clarified the boundary between meter profiles and the separately authenticated Codex desktop app.
- Added an in-app handoff to open Codex for desktop account switching.

## 1.3.2 — 2026-07-15

- Changed Add Account to the normal OpenAI browser sign-in flow so email, password, SSO and MFA stay on OpenAI's page.
- Isolated each saved account with file-scoped Codex credentials and activated it only after successful login.

## 1.3.1 — 2026-07-15

- Clarified USD, AUD and EUR symbols in model costs, savings and CLI output.
- Restored the translucent liquid-glass surface, material section depth and restrained native motion.

## 1.2.0 — 2026-07-15

- Added local token attribution by the model recorded for each Codex turn.
- Added model-by-model token totals, shares and API-equivalent estimates in the popover and CLI.
- Added persistent USD, AUD and EUR display currencies plus CLI exchange-rate overrides.
- Added automatic standard pricing for locally observed GPT-5.4, GPT-5.5 and GPT-5.6 model families from official OpenAI model pages.
- Added explicit price-source dating, unknown-model handling and custom fallback rates.
- Bumped history JSON to schema version 2 with structured pricing metadata.
- Expanded model-switch, duplicate-log, counter-reset, unknown-model and pricing coverage.

## 1.3.0 — 2026-07-15

- Added isolated `CODEX_HOME` account profiles with supported device-login flow and one-click hot swap.
- Added collapsible usage, local-activity and settings sections.
- Added menu-bar savings total and in-app milestone banners for savings, tokens, low usage and banked resets.

## 1.1.0 — 2026-07-15

- Added privacy-safe seven-day token activity history from local Codex session logs.
- Added a compact native activity chart in the popover.
- Added optional API-equivalent cost estimates with user-owned rates.
- Added four configurable menu-bar display modes.
- Added the universal `codex-meter` CLI with JSON, history and threshold exit codes.
- Added explicit privacy documentation and the production WidgetKit signing roadmap.
- Expanded honest-error, inspectability, low-footprint and zero-dependency product positioning.

## 1.0.0 — 2026-07-15

- Added native menu-bar usage display.
- Added primary and secondary Codex usage windows with local reset times.
- Added configurable low-usage notifications and launch-at-login support.
- Added resilient multi-bucket response parsing and unit coverage.
- Added universal Apple silicon and Intel packaging.
- Added open-source community, security, CI, and release documentation.
