# ADDENDUM to PROMPT.md: AI agents tab

These changes amend PROMPT.md and are part of Phase 1. Where they conflict with PROMPT.md, this addendum wins.

## Amendments to PROMPT.md
- Scope: the app also includes an AI agents tab. Never read, copy, or use another app's login tokens, OAuth credentials, API keys, cookies, or Keychain items, and never call undocumented web endpoints. The only network access allowed is the opt-in lyrics lookup and, only if the rules below allow it, an opt-in agent limits request.
- Island tabs: Home, AirDrop, Shelf, and Agents. The Agents icon only appears when the feature is enabled.
- Lock screen: show no agents content there.
- Settings: add AI agents on/off with per-agent toggles, completion notice on/off and threshold, header limit chip on/off, and any opt-in agent limits request with its disclosure text.
- Quality bar: add the agents tests and checks listed at the end of this file.
- Phase 1 finish: the README gets an agents privacy note (what is read locally, and that no prompt text is ever read). The Phase 1 report must say, for each agent, whether real plan-limit data was available and from what source, or what the credential-based route would be so I can decide.

## AI agents tab (off by default, enabled in Settings)
Goal: show how much of each AI coding agent's plan limit is used and when it resets, plus what each agent is doing right now. Supported agents: Claude Code, Codex, OpenCode, and GitHub Copilot (CLI or app). Detect which agents are present and used on this Mac and show only those. Show a clean empty state when none are found.

Data sources, local first:
- Read only each agent's local session and usage files on this Mac. Inspect the real folders on this machine to find them (for example ~/.claude/projects and ~/.codex/sessions are likely, but verify; check OpenCode and Copilot locations the same way). Do not assume file formats. Tolerate schema changes, unknown fields, malformed lines, and a partially written last line.
- Parse metadata only: timestamps, model names, token counts, project folder name, session id. Never display, log, store, cache, or transmit prompt text, responses, file contents, or tool output. When testing, never print the contents of real session files.
- Read incrementally: remember byte offsets per file, watch with FSEvents or DispatchSource, handle file rotation and truncation, never rescan everything, and do no polling while no agent is active. Idle CPU stays near zero.

What to show per agent:
- Plan limits: for each rolling or weekly window the agent reports, the percent used and a countdown to reset, color-coded (calm, warning, critical). Show this only where a trustworthy source exists.
- Tokens used today and this week, split by model. Current project name. Live state (working, idle, waiting) with a small activity indicator. Session count.
- Completion notice: when a long-running task finishes (activity lasted at least N minutes, default 2, then went idle), briefly expand the island like a device pop-up showing the agent, the project, and the duration. Queue it with other pop-ups, never interrupt a drag, never fire twice for the same task, and add a toggle plus a threshold setting.
- Optional small header chip next to the battery showing the highest percent used across visible windows. Off by default.

Rules for plan-limit data (important):
- Local logs usually do NOT contain plan-limit percentages. Research what each agent officially offers (official docs, official CLI commands, documented statusline or JSON output, documented local files). Prefer any source that needs no credentials.
- Never use a credential to get limits: no reading another app's token, OAuth data, API key, cookie, or Keychain item, and no undocumented endpoints. If the only route to a limit would need that, do NOT implement it. Show "Limit data not available" for that agent and describe the route in the Phase 1 report (what it would touch and the risks) so I can decide.
- Any network request this feature makes must be opt-in per agent, go only to that agent's own provider by documented means, and the toggle must state exactly what is sent. If no such route exists, this feature makes no network requests at all.
- Never show a limit number you cannot source, and never present a guess from token counts as a limit. Label anything estimated as an estimate, or leave it out.
- Display only. Take no actions on any account (no redeeming, resetting, or changing anything).

## Agents tests and checks
- Unit tests using synthetic fixture files (never real prompts): token, model, and project parsing per agent; malformed lines, a partial last line, unknown fields, and schema drift tolerated; missing agent folders; file rotation and truncation; incremental reading with offsets; the completion notice state machine (threshold, no duplicates, queueing with other pop-ups); a privacy test proving no prompt, response, or file-content text reaches the model, logs, or cache; "Limit data not available" shown when no trustworthy source exists; no network calls when the feature or its opt-in is off.
- Run it for real: capture the Agents tab and the completion notice with screencapture, and verify against any agents actually used on this Mac (the Claude Code session building this app is a live test case) without printing session contents.
