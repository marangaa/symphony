# Symphony Repo Connection Playbook

This guide explains how Symphony is connected to a specific repository and how to run it in a team setup.

## 1) Quick answer: is WORKFLOW.md auto-generated?

No, not by runtime startup.

What code does:

- CLI expects an existing workflow file path.
- If no path is passed, CLI tries ./WORKFLOW.md in current directory.
- Startup fails when the file does not exist.

Relevant modules:

- CLI path handling: symphony/elixir/lib/symphony_elixir/cli.ex
- workflow loading: symphony/elixir/lib/symphony_elixir/workflow.ex
- hot-reload cache: symphony/elixir/lib/symphony_elixir/workflow_store.ex

So your impression is understandable, but runtime does not create WORKFLOW.md automatically. The repository already ships one in symphony/elixir/WORKFLOW.md.

## 2) Mental model: how Symphony targets a repo

Symphony itself is the orchestrator process. It does not hard-bind to one code repository at compile time.

Target repository is determined by workspace bootstrap behavior in your workflow hooks:

1. Symphony creates per-issue workspace directories.
2. hooks.after_create runs.
3. That hook usually clones your target repository into the workspace.
4. Codex runs inside that workspace for that issue.

So repository targeting is policy/config, not hardcoded orchestration logic.

## 3) Where this is implemented

Main runtime mapping:

- Orchestration loop and dispatch: symphony/elixir/lib/symphony_elixir/orchestrator.ex
- Workspace creation and hook execution: symphony/elixir/lib/symphony_elixir/workspace.ex
- Codex app-server launch inside workspace: symphony/elixir/lib/symphony_elixir/codex/app_server.ex
- Prompt rendering from workflow + issue data: symphony/elixir/lib/symphony_elixir/prompt_builder.ex
- Tracker adapter selection: symphony/elixir/lib/symphony_elixir/tracker.ex

## 4) Recommended setup for your team

Use one workflow file per target repository/environment. Example naming:

- WORKFLOW.resonate.md
- WORKFLOW.platform.md
- WORKFLOW.staging.md

Then run Symphony by passing the explicit file path.

This avoids accidental cross-repo confusion and keeps routing explicit.

## 5) Minimal connection checklist

1. Choose tracker kind:
   - linear or supabase
2. Set workspace root:
   - workspace.root points to a base directory for issue workspaces
3. Set hooks.after_create:
   - clone the intended target repository into workspace
4. Set codex command:
   - codex app-server command and sandbox policy
5. Start Symphony with explicit workflow path and dashboard port

## 6) Example after_create for a connected repo

Use this pattern in workflow front matter:

hooks:
  after_create: |
    git clone --depth 1 https://github.com/your-org/your-repo.git .
    if command -v mise >/dev/null 2>&1; then
      mise trust || true
      mise exec -- mix deps.get || true
    fi

You can swap in pnpm/npm/bootstrap commands for non-Elixir repos.

## 7) Startup commands (Windows shell)

From symphony/elixir:

- Build once if needed: mise exec -- mix build
- Start with explicit workflow + dashboard:
  mise exec -- escript .\bin\symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails .\WORKFLOW.md --port 4040

Dashboard:

- http://127.0.0.1:4040/

## 8) Operational notes

- The dashboard is optional; terminal status still works without --port.
- Workflow file changes are picked up by WorkflowStore polling reload.
- Missing/invalid workflow keeps startup from proceeding.
- Runtime can continue on last known good workflow if later reload fails.

## 9) Suggested structure for your next iteration

1. Keep one canonical workflow per real repo.
2. Keep tracker routing conservative first (stable active states and capacities).
3. Keep hook scripts simple and deterministic.
4. Add repo-specific skills only after base flow is stable.

This gives predictable orchestration before adding more policy complexity.
