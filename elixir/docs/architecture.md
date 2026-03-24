# Symphony Elixir Architecture (End-to-End)

This document explains the real runtime flow used by the Elixir implementation in this repo.

It is focused on practical operation: where issues are ingested, how they are normalized, when runs are dispatched or blocked, how retries work, and what happens at completion.

## 1) System Components

Core modules:

- `SymphonyElixir.Workflow` loads and parses `WORKFLOW.md`.
- `SymphonyElixir.Config` converts workflow config into typed runtime settings and validates semantics.
- `SymphonyElixir.Tracker` chooses tracker adapter (`linear`, `memory`, `supabase`).
- `SymphonyElixir.Orchestrator` owns polling, dispatching, claiming, retries, and reconciliation.
- `SymphonyElixir.AgentRunner` executes one issue attempt in a workspace.
- `SymphonyElixir.Workspace` manages per-issue local/remote workspace lifecycle and hooks.
- `SymphonyElixir.Codex.AppServer` drives Codex app-server sessions/turns.
- `SymphonyElixir.Codex.DynamicTool` exposes dynamic tools to Codex (currently `linear_graphql`).

## 2) Ingestion Flow (Tracker -> Candidate Issues)

### Step A: Load workflow and runtime config

1. `Workflow.current/0` reads front matter + prompt template from `WORKFLOW.md`.
2. `Config.settings!/0` parses into typed schema values.
3. `Config.validate!/0` enforces required fields by tracker kind:
   - linear: `api_key`, `project_slug`
   - supabase: `supabase_url`, `supabase_secret_key`

### Step B: Poll candidates

1. `Orchestrator` tick triggers `maybe_dispatch/1`.
2. `Tracker.fetch_candidate_issues/0` routes to configured adapter.
3. Adapter returns a list of normalized `%SymphonyElixir.Linear.Issue{}` structs.

### Step C: Normalize tracker payloads

All adapters normalize into the same internal issue struct shape before orchestration.

Why: orchestration logic is tracker-agnostic and uses a single model.

## 3) Why the Issue Mapper Exists

The issue mapper is the translation boundary from tracker-specific payloads into a stable issue contract.

For Supabase, this is `SymphonyElixir.Supabase.IssueMapper`.

It handles:

- Required identity fields (`tracker_item_id`, `tracker_identifier`, `title`, `state`).
- Priority normalization (`critical|high|medium|low` -> `1..4`).
- Assignee routing normalization (`assigned_to_worker` strings/booleans to a final boolean).
- `blocked_by` shape normalization (safe fallback to `[]`).
- Datetime parsing for deterministic sorting/reconciliation.

This is normal and matches the same concept in the Linear path: Linear also performs normalization (`normalize_issue/2`, blockers extraction, labels extraction, datetime parsing) before handing data to orchestrator logic.

In short: mapper/normalizers are not extra complexity, they are the compatibility layer that keeps orchestrator code simple and stable.

## 4) Dispatch Eligibility and Blocking Rules

Before dispatch, Symphony checks:

- Issue is in an active state.
- Issue is not in terminal state.
- Issue is not already claimed/running.
- Global slots are available.
- Per-state concurrency slots are available.
- Worker/assignee routing says this worker should run it.

Current blocking semantics:

- `Todo` issues with `blocked_by` entries that are not terminal are not dispatched.
- Non-`Todo` states are not blocked by `blocked_by` today.
- `assigned_to_worker == false` means do not dispatch to this orchestrator worker.

## 5) Execution Lifecycle (One Issue)

1. `Orchestrator` claims issue and spawns a supervised task.
2. `AgentRunner.run/3` selects worker host (local or SSH host).
3. `Workspace.create_for_issue/2` ensures workspace exists.
4. `Workspace` runs `after_create` hook when workspace is newly created.
5. `Workspace` runs `before_run` hook.
6. `Codex.AppServer.start_session/2` starts app-server and thread.
7. Prompt is rendered from template + normalized issue (`PromptBuilder.build_prompt/2`).
8. `Codex.AppServer.run_turn/4` executes a turn, streams updates to orchestrator.
9. If issue remains active and `max_turns` not reached, continuation turns run automatically.
10. `after_run` hook runs.
11. Task exits:
    - `:normal` -> schedules a short continuation retry/check.
    - abnormal exit -> schedules retry with backoff.

## 6) Retry, Reconciliation, and Stall Recovery

Retry sources:

- Agent process crash/exit.
- Spawn failures.
- Poll failures.
- No dispatch slots currently available.
- Normal continuation checks.

Behavior:

- Exponential backoff for failures (`@failure_retry_base_ms`, bounded by config max).
- Short delay for normal continuation checks (`@continuation_retry_delay_ms`).
- Periodic reconciliation refreshes current state of running issues.
- If a running issue moves terminal/non-active/no-longer-routable -> task is stopped.
- Stall watchdog restarts runs with backoff when no Codex activity exceeds configured timeout.

## 7) Completion and Cleanup

When issue becomes terminal (e.g., Done/Closed):

- Active run is stopped.
- Claim/retry state is released.
- Workspace cleanup can run for terminal items.

On startup, Symphony also fetches terminal-state issues and performs terminal workspace cleanup to avoid stale folders.

## 8) Comment and State Write-backs

Tracker write APIs used by orchestrator side:

- `update_issue_state(issue_id, state_name)`
- `create_comment(issue_id, body)`

For Supabase adapter:

- State updates patch `roadmap_items.status`.
- Comment writes are durable and now persisted via `loop_events`:
  - resolve issue context from `tracker_work_items_v1`
  - map to linked `loop_items`
  - insert `loop_events` (`event_type: orchestrator_comment`, `actor_type: system`, metadata includes comment body)
  - touch `loop_items.last_event_at` and `updated_at`

This is not inbox sync. It is orchestration event history/audit persistence.

## 9) Skills and .codex Integration

Repo skills live in `symphony/.codex/skills`.

Current skill folders:

- `commit`
- `debug`
- `land`
- `linear`
- `pull`
- `push`

How they fit:

- Skills are consumed by the Codex session prompt/workflow conventions.
- `Codex.DynamicTool` currently injects `linear_graphql` for direct Linear operations during runs.
- Additional operational behaviors (for example unblock-assignee conventions) can be encoded via skills + workflow prompt policy.

## 10) "Blocked but Assigned" Design Note

Your instinct is right: assignment should usually imply ownership to unblock.

Current behavior only blocks dispatch for `Todo` with non-terminal blockers. That is intentionally conservative but may be too narrow for some teams.

A practical next step:

1. Keep existing default behavior for compatibility.
2. Add optional policy in workflow config, for example:
   - `dispatch.blocked_policy: todo_only | all_active | ignore`
3. Add optional ownership escalation rule:
   - if assigned and blocked, require periodic unblock comment/event update.
4. Implement as a small orchestrator policy layer, not tracker-specific logic.

## 11) End-to-End Sequence (Compact)

1. Load/validate `WORKFLOW.md`.
2. Poll tracker adapter for active candidates.
3. Normalize payloads to `%Linear.Issue{}`.
4. Filter/route candidates (state, blockers, assignee, capacity).
5. Create/prepare workspace and run hooks.
6. Start Codex app-server session and execute turns.
7. Stream telemetry, reconcile issue state, and retry/continue as needed.
8. Persist tracker-side updates/comments.
9. Stop/cleanup when issue leaves active flow or reaches terminal.

## 12) Operational Gaps Noted

Areas where README is intentionally brief but operations care:

- Detailed retry token/backoff lifecycle.
- Stall detection and restart behavior.
- Worker host pinning during retries.
- Per-state concurrency gates.
- Supabase comment sink semantics and timeline/event persistence.
- Exact blocker gate scope (`Todo`-only today).

This document is intended to close those gaps.
