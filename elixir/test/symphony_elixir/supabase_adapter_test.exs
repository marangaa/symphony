defmodule SymphonyElixir.SupabaseAdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Supabase.Adapter
  alias SymphonyElixir.Supabase.IssueMapper

  defmodule FakeSupabaseClient do
    alias SymphonyElixir.Linear.Issue

    def fetch_candidate_issues do
      {:ok,
       [
         %Issue{
           id: "item-1",
           identifier: "RM-ITEM1",
           title: "First item",
           state: "planned",
           assigned_to_worker: true,
           blocked_by: []
         }
       ]}
    end

    def fetch_issues_by_states(_states), do: fetch_candidate_issues()

    def fetch_issue_states_by_ids(ids) do
      {:ok, Enum.filter(elem(fetch_candidate_issues(), 1), &(&1.id in ids))}
    end

    def create_comment(issue_id, body) do
      send(self(), {:fake_supabase_comment, issue_id, body})
      :ok
    end

    def update_issue_state(issue_id, state_name) do
      send(self(), {:fake_supabase_state, issue_id, state_name})
      :ok
    end
  end

  setup do
    previous_module = Application.get_env(:symphony_elixir, :supabase_client_module)

    on_exit(fn ->
      if is_nil(previous_module) do
        Application.delete_env(:symphony_elixir, :supabase_client_module)
      else
        Application.put_env(:symphony_elixir, :supabase_client_module, previous_module)
      end
    end)

    :ok
  end

  test "tracker selects supabase adapter when configured" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "supabase",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_supabase_url: "https://example.supabase.co",
      tracker_supabase_secret_key: "secret"
    )

    assert Tracker.adapter() == SymphonyElixir.Supabase.Adapter
  end

  test "supabase adapter delegates to configured client module" do
    Application.put_env(:symphony_elixir, :supabase_client_module, FakeSupabaseClient)

    assert {:ok, issues} = Adapter.fetch_candidate_issues()
    assert Enum.map(issues, & &1.id) == ["item-1"]

    assert :ok = Adapter.create_comment("item-1", "hello")
    assert :ok = Adapter.update_issue_state("item-1", "in_progress")

    assert_received {:fake_supabase_comment, "item-1", "hello"}
    assert_received {:fake_supabase_state, "item-1", "in_progress"}
  end

  test "config validates supabase credentials from env when not set in workflow" do
    previous_url = System.get_env("SUPABASE_URL")
    previous_key = System.get_env("SUPABASE_SECRET_KEY")

    on_exit(fn ->
      restore_env("SUPABASE_URL", previous_url)
      restore_env("SUPABASE_SECRET_KEY", previous_key)
    end)

    System.put_env("SUPABASE_URL", "https://env-project.supabase.co")
    System.put_env("SUPABASE_SECRET_KEY", "env-secret")

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "supabase",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_supabase_url: nil,
      tracker_supabase_secret_key: nil
    )

    assert Config.settings!().tracker.supabase_url == "https://env-project.supabase.co"
    assert Config.settings!().tracker.supabase_secret_key == "env-secret"
    assert :ok = Config.validate!()
  end

  test "config returns required supabase credential errors when missing" do
    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "supabase",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_supabase_url: nil,
      tracker_supabase_secret_key: nil
    )

    previous_url = System.get_env("SUPABASE_URL")
    previous_key = System.get_env("SUPABASE_SECRET_KEY")

    on_exit(fn ->
      restore_env("SUPABASE_URL", previous_url)
      restore_env("SUPABASE_SECRET_KEY", previous_key)
    end)

    System.delete_env("SUPABASE_URL")
    System.delete_env("SUPABASE_SECRET_KEY")

    assert {:error, :missing_supabase_url} = Config.validate!()

    System.put_env("SUPABASE_URL", "https://env-project.supabase.co")
    assert {:error, :missing_supabase_secret_key} = Config.validate!()
  end

  test "issue mapper normalizes supabase tracker rows" do
    row = %{
      "tracker_item_id" => "d7a9e081-2ecf-4b56-a309-5f53a75d31e4",
      "tracker_identifier" => "RM-D7A9E081",
      "title" => "Ship polling adapter",
      "state" => "planned",
      "priority" => "high",
      "description" => "Read from tracker_work_items_v1",
      "assigned_to_worker" => "codex",
      "blocked_by" => [%{"id" => "X-1", "state" => "done"}],
      "created_at" => "2026-03-23T10:05:00Z",
      "updated_at" => "2026-03-23T12:20:00Z"
    }

    assert issue = IssueMapper.from_row(row, "codex")
    assert issue.id == "d7a9e081-2ecf-4b56-a309-5f53a75d31e4"
    assert issue.identifier == "RM-D7A9E081"
    assert issue.priority == 2
    assert issue.assigned_to_worker
    assert [%{"id" => "X-1", "state" => "done"}] = issue.blocked_by
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at
  end
end
