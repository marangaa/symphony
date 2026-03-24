defmodule SymphonyElixir.SupabaseClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Supabase.Client

  setup do
    previous_request_fun = Application.get_env(:symphony_elixir, :supabase_request_fun)

    on_exit(fn ->
      if is_nil(previous_request_fun) do
        Application.delete_env(:symphony_elixir, :supabase_request_fun)
      else
        Application.put_env(:symphony_elixir, :supabase_request_fun, previous_request_fun)
      end
    end)

    write_workflow_file!(Workflow.workflow_file_path(),
      tracker_kind: "supabase",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_supabase_url: "https://example.supabase.co",
      tracker_supabase_secret_key: "secret"
    )

    :ok
  end

  test "create_comment persists loop event and touches loop item" do
    parent = self()

    request_fun = fn opts ->
      send(parent, {:supabase_request, opts[:method], opts[:url], opts[:params], opts[:json]})

      case {opts[:method], opts[:url]} do
        {:get, "/rest/v1/tracker_work_items_v1"} ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "tracker_item_id" => "item-1",
                 "tracker_identifier" => "RM-001",
                 "roadmap_item_id" => "roadmap-1",
                 "tenant_id" => "tenant-1"
               }
             ]
           }}

        {:get, "/rest/v1/loop_items"} ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "id" => "loop-1",
                 "tenant_id" => "tenant-1",
                 "decision_id" => "decision-1",
                 "insight_id" => nil,
                 "roadmap_item_id" => "roadmap-1"
               }
             ]
           }}

        {:post, "/rest/v1/loop_events"} ->
          {:ok, %{status: 201, body: []}}

        {:patch, "/rest/v1/loop_items"} ->
          {:ok, %{status: 200, body: []}}

        _ ->
          {:error, {:unexpected_request, opts}}
      end
    end

    Application.put_env(:symphony_elixir, :supabase_request_fun, request_fun)

    assert :ok = Client.create_comment("item-1", "hello from orchestrator")

    assert_received {:supabase_request, :post, "/rest/v1/loop_events", _params,
                     %{
                       "event_type" => "orchestrator_comment",
                       "tenant_id" => "tenant-1",
                       "loop_item_id" => "loop-1",
                       "roadmap_item_id" => "roadmap-1",
                       "actor_type" => "system",
                       "metadata" => %{"source" => "symphony_orchestrator", "comment_body" => "hello from orchestrator"}
                     }}

    assert_received {:supabase_request, :patch, "/rest/v1/loop_items", %{"id" => "eq.loop-1"},
                     %{"last_event_at" => _last_event_at, "updated_at" => _updated_at}}
  end

  test "create_comment is no-op when comment is blank" do
    parent = self()

    request_fun = fn opts ->
      send(parent, {:supabase_request, opts[:method], opts[:url], opts[:params], opts[:json]})
      {:error, :should_not_call_supabase}
    end

    Application.put_env(:symphony_elixir, :supabase_request_fun, request_fun)

    assert :ok = Client.create_comment("item-1", "   \n  ")
    refute_received {:supabase_request, _method, _url, _params, _body}
  end

  test "create_comment gracefully skips when roadmap item is not linked to loop item" do
    parent = self()

    request_fun = fn opts ->
      send(parent, {:supabase_request, opts[:method], opts[:url], opts[:params], opts[:json]})

      case {opts[:method], opts[:url]} do
        {:get, "/rest/v1/tracker_work_items_v1"} ->
          {:ok,
           %{
             status: 200,
             body: [
               %{
                 "tracker_item_id" => "item-1",
                 "tracker_identifier" => "RM-001",
                 "roadmap_item_id" => "roadmap-1",
                 "tenant_id" => "tenant-1"
               }
             ]
           }}

        {:get, "/rest/v1/loop_items"} ->
          {:ok, %{status: 200, body: []}}

        _ ->
          {:error, {:unexpected_request, opts}}
      end
    end

    Application.put_env(:symphony_elixir, :supabase_request_fun, request_fun)

    assert :ok = Client.create_comment("item-1", "still fine")

    refute_received {:supabase_request, :post, "/rest/v1/loop_events", _params, _body}
    refute_received {:supabase_request, :patch, "/rest/v1/loop_items", _params, _body}
  end
end
