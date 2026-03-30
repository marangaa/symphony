defmodule SymphonyElixir.Supabase.Adapter do
  @moduledoc """
  Supabase-backed tracker adapter.

  Reads and writes roadmap items via the Supabase REST API using the
  `tracker_work_items_v1` view for reads and `roadmap_items` for writes.
  This is the canonical adapter when `tracker.kind == "supabase"`.
  """

  @behaviour SymphonyElixir.Tracker

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @select_fields "roadmap_item_id,tracker_item_id,tracker_identifier,title,state,priority,description,assigned_to_worker,blocked_by,tenant_id,created_at,updated_at"
  @comment_event_type "orchestrator_comment"
  @comment_metadata_source "symphony_orchestrator"
  @page_size 50

  # ---------------------------------------------------------------------------
  # Tracker callbacks
  # ---------------------------------------------------------------------------

  @impl SymphonyElixir.Tracker
  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_supabase_settings(tracker) do
      active_states = tracker.active_states
      fetch_by_state_filter(tracker, build_in_filter(active_states))
    end
  end

  @impl SymphonyElixir.Tracker
  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    case states do
      [] ->
        {:ok, []}

      _ ->
        tracker = Config.settings!().tracker

        with :ok <- validate_supabase_settings(tracker) do
          fetch_by_state_filter(tracker, build_in_filter(states))
        end
    end
  end

  @impl SymphonyElixir.Tracker
  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      _ ->
        tracker = Config.settings!().tracker

        with :ok <- validate_supabase_settings(tracker) do
          fetch_by_id_filter(tracker, ids)
        end
    end
  end

  @impl SymphonyElixir.Tracker
  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    tracker = Config.settings!().tracker

    with :ok <- validate_supabase_settings(tracker) do
      # Resolve tenant_id from the roadmap item
      case fetch_issue_tenant(tracker, issue_id) do
        {:ok, tenant_id} ->
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          payload = %{
            "tenant_id" => tenant_id,
            "loop_item_id" => nil,
            "roadmap_item_id" => issue_id,
            "actor_type" => "agent",
            "event_type" => @comment_event_type,
            "event_summary" => body,
            "metadata" => %{
              "source" => @comment_metadata_source
            },
            "created_at" => now
          }

          case request(tracker, :post, "/rest/v1/loop_events", body: payload) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              Logger.warning("[Supabase Adapter] Failed to insert comment for #{issue_id}: #{inspect(reason)}")
              {:error, reason}
          end

        {:error, reason} ->
          Logger.warning("[Supabase Adapter] Could not resolve tenant for comment on #{issue_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @impl SymphonyElixir.Tracker
  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with :ok <- validate_supabase_settings(tracker) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()

      case request(
             tracker,
             :patch,
             "/rest/v1/roadmap_items",
             params: %{"id" => "eq.#{issue_id}"},
             body: %{
               "status" => state_name,
               "updated_at" => now
             },
             headers: [{"prefer", "return=minimal"}]
           ) do
        {:ok, _} ->
          Logger.info("[Supabase Adapter] Updated issue #{issue_id} -> #{state_name}")
          :ok

        {:error, reason} ->
          Logger.warning("[Supabase Adapter] Failed to update issue #{issue_id} state: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_by_state_filter(tracker, state_filter) do
    params = %{
      "select" => @select_fields,
      "state" => state_filter,
      "order" => "created_at.asc",
      "limit" => to_string(@page_size)
    }

    with {:ok, rows} <- request(tracker, :get, "/rest/v1/tracker_work_items_v1", params: params) do
      normalize_rows(rows)
    end
  end

  defp fetch_by_id_filter(tracker, ids) do
    params = %{
      "select" => @select_fields,
      "tracker_item_id" => build_in_filter(ids),
      "order" => "created_at.asc",
      "limit" => to_string(length(ids) + 10)
    }

    with {:ok, rows} <- request(tracker, :get, "/rest/v1/tracker_work_items_v1", params: params) do
      normalize_rows(rows)
    end
  end

  defp fetch_issue_tenant(tracker, issue_id) do
    params = %{
      "select" => "tenant_id",
      "id" => "eq.#{issue_id}",
      "limit" => "1"
    }

    case request(tracker, :get, "/rest/v1/roadmap_items", params: params) do
      {:ok, [%{"tenant_id" => tid} | _]} when is_binary(tid) ->
        {:ok, tid}

      {:ok, []} ->
        {:error, :issue_not_found}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :unexpected_response}
    end
  end

  defp normalize_rows(rows) when is_list(rows) do
    issues =
      rows
      |> Enum.map(&normalize_row/1)
      |> Enum.reject(&is_nil/1)

    {:ok, issues}
  end

  defp normalize_rows(_), do: {:error, :unexpected_response}

  defp normalize_row(%{} = row) do
    %Issue{
      id: row["roadmap_item_id"] || row["tracker_item_id"],
      identifier: row["tracker_identifier"] || row["roadmap_item_id"],
      title: row["title"],
      description: row["description"],
      priority: parse_priority(row["priority"]),
      state: row["state"],
      branch_name: nil,
      url: nil,
      assignee_id: nil,
      blocked_by: parse_blocked_by(row["blocked_by"]),
      labels: [],
      assigned_to_worker: parse_assigned_to_worker(row["assigned_to_worker"]),
      created_at: parse_datetime(row["created_at"]),
      updated_at: parse_datetime(row["updated_at"])
    }
  end

  defp normalize_row(_row), do: nil

  defp parse_blocked_by(nil), do: []
  defp parse_blocked_by([]), do: []

  defp parse_blocked_by(items) when is_list(items) do
    Enum.flat_map(items, fn
      item when is_binary(item) -> [%{id: item, identifier: item, state: nil}]
      %{"id" => id, "state" => state} -> [%{id: id, identifier: id, state: state}]
      _ -> []
    end)
  end

  defp parse_blocked_by(_), do: []

  defp parse_assigned_to_worker(nil), do: true
  defp parse_assigned_to_worker(true), do: true
  defp parse_assigned_to_worker("true"), do: true
  defp parse_assigned_to_worker(false), do: false
  defp parse_assigned_to_worker("false"), do: false
  defp parse_assigned_to_worker(_), do: true

  defp parse_priority(priority) when is_integer(priority), do: priority

  defp parse_priority(priority) when is_binary(priority) do
    case Integer.parse(priority) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_priority(_), do: nil

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) when is_binary(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp build_in_filter([]), do: "in.()"

  defp build_in_filter(values) when is_list(values) do
    joined = Enum.map_join(values, ",", &URI.encode(&1))
    "in.(#{joined})"
  end

  defp validate_supabase_settings(tracker) do
    cond do
      not is_binary(tracker.supabase_url) or tracker.supabase_url == "" ->
        {:error, :missing_supabase_url}

      not is_binary(tracker.supabase_secret_key) or tracker.supabase_secret_key == "" ->
        {:error, :missing_supabase_secret_key}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP request helper (mirrors the pattern in supabase/client.ex)
  # ---------------------------------------------------------------------------

  defp request(tracker, method, path, opts \\ []) do
    url = String.trim_trailing(tracker.supabase_url, "/") <> path
    headers = supabase_headers(tracker)
    params = Keyword.get(opts, :params, %{})
    body = Keyword.get(opts, :body)
    extra_headers = Keyword.get(opts, :headers, [])
    all_headers = headers ++ extra_headers

    req_opts = [
      headers: all_headers,
      params: params,
      connect_options: [timeout: 30_000]
    ]

    result =
      case method do
        :get ->
          Req.get(url, req_opts)

        :post ->
          Req.post(url, Keyword.put(req_opts, :json, body))

        :patch ->
          Req.patch(url, Keyword.put(req_opts, :json, body))

        :delete ->
          Req.delete(url, req_opts)
      end

    case result do
      {:ok, %{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        Logger.warning("[Supabase Adapter] HTTP #{method |> Atom.to_string() |> String.upcase()} #{path} returned #{status}: #{inspect(response_body)}")
        {:error, {:http_status, status, response_body}}

      {:error, reason} ->
        Logger.warning("[Supabase Adapter] HTTP request failed: #{inspect(reason)}")
        {:error, {:http_error, reason}}
    end
  end

  defp supabase_headers(tracker) do
    [
      {"apikey", tracker.supabase_secret_key},
      {"Authorization", "Bearer #{tracker.supabase_secret_key}"},
      {"Content-Type", "application/json"},
      {"Accept", "application/json"}
    ]
  end
end
