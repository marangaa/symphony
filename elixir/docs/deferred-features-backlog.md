# Deferred Features Backlog

This file tracks ideas discussed that are intentionally not in the current priority path.

Goal: keep momentum on basics while preserving future design decisions.

## Priority rule

Do not implement items here until current baseline is stable:

- reliable polling and dispatch
- stable workspace bootstrap
- clear issue lifecycle in tracker
- durable event/comment sink behavior

## Deferred items

### 1) Blocking policy beyond Todo-only

Current behavior:

- blocker gating is strict for Todo dispatch only

Possible future enhancement:

- configurable policy, for example:
  - todo_only
  - all_active
  - ignore

Why deferred:

- policy choice changes throughput and queue behavior
- needs rollout/testing with real issue distribution

### 2) Assigned-but-blocked ownership rules

Idea:

- if an item is assigned and blocked, require explicit unblock ownership behavior

Possible implementation:

- orchestration policy + skill guidance for unblock updates
- periodic blocker status/comment check-ins

Why deferred:

- requires team conventions first (who owns unblock updates and cadence)

### 3) Skill-driven unblock protocol

Idea:

- add dedicated skill in symphony/.codex/skills for blocked workflows

Possible scope:

- detect blocker type
- choose action path
- update tracker comment/state consistently

Why deferred:

- should follow decision on blocking policy and assignment semantics

### 4) Frontend visibility for tracker contract state

Idea:

- surface tracker contract validity and identifiers in UI

Possible scope:

- roadmap drawer badge
- linked tracker identifiers
- latest orchestration event visibility

Why deferred:

- backend baseline first; avoid UX churn while core flow settles

### 5) Enhanced dashboard panels

Idea:

- richer operator panels for stalled runs, blocker counts, and repo health signals

Why deferred:

- current dashboard is sufficient for baseline operations
- better to evolve after field usage patterns are observed

### 6) Multi-repo orchestration templates

Idea:

- standardized workflow templates for multiple repos/environments

Why deferred:

- first establish one reliable connected-repo flow end-to-end

## Revisit trigger

Re-open this backlog after:

1. one stable production-like run cycle completes
2. blocker patterns are observed over at least one sprint
3. no critical startup/routing regressions for one release window

## Notes for future decision review

When promoting an item from this backlog, capture:

- problem statement
- expected operational impact
- rollout and rollback plan
- test/validation approach
