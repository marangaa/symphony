---
name: supabase
description:
  Manage roadmap item state and record build artifacts in Supabase using the
  dynamic tools provided by Symphony. Use when asked to update state, record
  a PR URL, or move an item to Human Review / Done / Rework.
---

# Supabase State Management

## Context

When Symphony runs in Supabase mode, the roadmap item state is stored directly
in `roadmap_items.status`. Two dynamic tools are available in your session to
interact with this state:

| Tool | Purpose |
|---|---|
| `supabase_update_state` | Transition the roadmap item to a new state |
| `supabase_set_pr_url` | Record the GitHub PR URL on the roadmap item |

These tools are only available when `tracker.kind = "supabase"` is configured.
**Do not use `linear_graphql` for state management when in Supabase mode.**

## supabase_update_state

Use this to move the item between states. The Symphony orchestrator has
already set the item to `In Progress` when it was claimed — do NOT set
`In Progress` again at session start.

```json
{
  "tool": "supabase_update_state",
  "arguments": {
    "issue_id": "<tracker_item_id from session context>",
    "state": "Human Review"
  }
}
```

### Valid target states

| State | When to use |
|---|---|
| `Human Review` | Work is complete and a PR exists; awaiting human review before merge |
| `Rework` | A blocker was found that needs human input; describe the blocker in the workpad comment |
| `Done` | All work is done AND the PR has been merged (use after `land` skill completes) |
| `Closed` | The item is cancelled (use only if the item description is invalid or out of scope) |

## supabase_set_pr_url

Call this **immediately after** a PR is opened (before transitioning to
`Human Review`). This persists the PR link on the roadmap item and triggers
an inbox notification so the team can review and approve the build.

```json
{
  "tool": "supabase_set_pr_url",
  "arguments": {
    "issue_id": "<tracker_item_id from session context>",
    "pr_url": "https://github.com/org/repo/pull/42"
  }
}
```

Get the PR URL from `gh pr view --json url -q .url` after pushing (see `push`
skill for full push + PR creation flow).

## Standard completion flow

```
1. Implement changes
2. Run validation (make all / relevant test command)
3. Commit          ← use commit skill
4. Push + create PR← use push skill → returns PR URL
5. Record PR URL:
     supabase_set_pr_url(issue_id, pr_url)
6. Transition state:
     supabase_update_state(issue_id, "Human Review")
```

## Blocked / Rework flow

If you cannot complete the task due to a true blocker (missing secrets,
external auth, unclear requirements):

1. Write the blocker clearly in the workpad comment.
2. Call `supabase_update_state` with state `"Rework"`.
3. Stop the session — do not ask the human to perform follow-up.

## Done flow (after land/merge)

Only call `Done` after the `land` skill has confirmed the PR was squash-merged:

1. Run `land` skill to squash-merge the PR.
2. On successful merge: `supabase_update_state(issue_id, "Done")`.

## Notes

- `issue_id` is the UUID from the session context (`{{ issue.id }}` in the
  workflow template). Do not use the `RM-XXXXXXXX` identifier here — the
  tool expects the raw UUID.
- State names are **case-sensitive** and must be Title Case exactly as shown.
- If a tool call fails, log the error and retry once. If it fails twice, write
  the error to the workpad comment and stop.
