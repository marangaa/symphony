defmodule SymphonyElixir.Supabase.Client do
  @moduledoc false

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Supabase.IssueMapper

  @select_fields "tracker_item_id,tracker_identifier,title,state,priority,description,assigned_to_worker,blocked_by,created_at,updated_at,tenant_id"
  @loop_context_select "id,tenant_id,decision_id,insight_id,roadmap_item_id"
  @comment_event_type "orchestrator_comment"
  @comment_metadata_source "symphony_orchestrator"

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_supabase_settings(tracker),
         {:ok, rows} <- list_work_items(tracker, %{"state" => in_filter(tracker.active_states)}),
         {:ok, issues} <- normalize_rows(rows, tracker) do
      {:ok, issues}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker
    states = state_names |> Enum.map(&to_string/1) |> Enum.uniq()

    cond do
      states == [] ->
        {:ok, []}

      true ->
        with :ok <- validate_supabase_settings(tracker),
             {:ok, rows} <- list_work_items(tracker, %{"state" => in_filter(states)}),
             {:ok, issues} <- normalize_rows(rows, tracker) do
          {:ok, issues}
        end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    tracker = Config.settings!().tracker
    ids = Enum.uniq(issue_ids)

    cond do
      ids == [] ->
        {:ok, []}

      true ->
        with :ok <- validate_supabase_settings(tracker),
             {:ok, rows} <- list_work_items(tracker, %{"tracker_item_id" => in_filter(ids)}),
             {:ok, issues} <- normalize_rows(rows, tracker) do
          sorted_issues = sort_issues_by_ids(issues, ids)
          {:ok, sorted_issues}
        end
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    tracker = Config.settings!().tracker

    with :ok <- validate_supabase_settings(tracker),
         {:ok, _response} <-
           patch_item_state(
             tracker,
             issue_id,
             %{"status" => state_name, "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()}
           ) do
      :ok
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    comment_body = String.trim(body)

    if comment_body == "" do
      :ok
    else
      tracker = Config.settings!().tracker

      with :ok <- validate_supabase_settings(tracker),
           {:ok, loop_context} <- fetch_loop_context_for_issue(tracker, issue_id),
           :ok <- write_comment_event(tracker, loop_context, issue_id, comment_body),
           :ok <- touch_loop_item(tracker, loop_context["loop_item_id"]) do
        :ok
      end
    end
  end

  defp normalize_rows(rows, tracker) when is_list(rows) do
    {issues, _cache} =
      Enum.reduce(rows, {[], %{}}, fn row, {acc, cache} ->
        case IssueMapper.from_row(row, tracker.assignee) do
          %Issue{} = issue ->
            tenant_id = normalize_tenant_id(Map.get(row, "tenant_id"))
            {repo_context, updated_cache} = repo_context_for_tenant(tracker, tenant_id, cache)
            {[apply_repo_context(issue, repo_context) | acc], updated_cache}

          _ ->
            {acc, cache}
        end
      end)

    {:ok, Enum.reverse(issues)}
  end

  defp normalize_rows(_rows, _tracker), do: {:error, :invalid_supabase_payload}

  defp repo_context_for_tenant(_tracker, nil, cache), do: {nil, cache}

  defp repo_context_for_tenant(tracker, tenant_id, cache) do
    case Map.fetch(cache, tenant_id) do
      {:ok, repo_context} ->
        {repo_context, cache}

      :error ->
        repo_context =
          case fetch_repo_context(tracker, tenant_id) do
            {:ok, context} ->
              context

            {:error, reason} ->
              Logger.warning(
                "Supabase repo context lookup failed for tenant_id=#{tenant_id}: #{inspect(reason)}"
              )

              nil
          end

        {repo_context, Map.put(cache, tenant_id, repo_context)}
    end
  end

  defp fetch_repo_context(tracker, tenant_id) do
    path = "/rest/v1/tenant_github_repos"

    params = %{
      "select" => "repo_full_name,repo_url,is_default",
      "tenant_id" => "eq.#{tenant_id}",
      "order" => "is_default.desc,created_at.asc"
    }

    with {:ok, rows} <- request(tracker, :get, path, params: params) do
      candidates =
        rows
        |> List.wrap()
        |> Enum.map(fn row ->
          %{
            repo_full_name: normalize_tenant_id(Map.get(row, "repo_full_name")),
            repo_url: normalize_tenant_id(Map.get(row, "repo_url")),
            is_default: Map.get(row, "is_default") == true
          }
        end)
        |> Enum.filter(fn repo -> is_binary(repo.repo_url) end)

      case candidates do
        [primary | _rest] ->
          {:ok, %{primary: primary, candidates: candidates}}

        [] ->
          {:ok, nil}
      end
    end
  end

  defp apply_repo_context(issue, nil), do: issue

  defp apply_repo_context(%Issue{} = issue, repo_context) when is_map(repo_context) do
    %Issue{
      issue
      | repo_full_name: repo_context.primary.repo_full_name,
        repo_candidates: repo_context.candidates,
        url: repo_context.primary.repo_url || issue.url
    }
  end

  defp normalize_tenant_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_tenant_id(_value), do: nil

  defp sort_issues_by_ids(issues, ids) do
    rank = ids |> Enum.with_index() |> Map.new()
    fallback = map_size(rank)

    Enum.sort_by(issues, fn %Issue{id: id} -> Map.get(rank, id, fallback) end)
  end

  defp list_work_items(tracker, filters) do
    path = "/rest/v1/#{tracker.supabase_view_name}"

    params =
      %{
        "select" => @select_fields,
        "order" => "updated_at.asc"
      }
      |> Map.merge(filters)

    request(tracker, :get, path, params: params)
  end

  defp patch_item_state(tracker, issue_id, attrs) do
    path = "/rest/v1/#{tracker.supabase_items_table}"

    request(
      tracker,
      :patch,
      path,
      params: %{"id" => "eq.#{issue_id}"},
      body: attrs,
      headers: [{"prefer", "return=representation"}]
    )
  end

  defp fetch_loop_context_for_issue(tracker, issue_id) do
    with {:ok, row} <- fetch_work_item_row(tracker, issue_id),
         {:ok, loop_item} <- fetch_loop_item_row(tracker, row) do
      {:ok,
       %{
         "loop_item_id" => loop_item["id"],
         "tenant_id" => loop_item["tenant_id"],
         "decision_id" => loop_item["decision_id"],
         "insight_id" => loop_item["insight_id"],
         "roadmap_item_id" => loop_item["roadmap_item_id"],
         "tracker_identifier" => row["tracker_identifier"]
       }}
    end
  end

  defp fetch_work_item_row(tracker, issue_id) do
    path = "/rest/v1/#{tracker.supabase_view_name}"

    params = %{
      "select" => "tracker_item_id,tracker_identifier,roadmap_item_id,tenant_id",
      "tracker_item_id" => "eq.#{issue_id}",
      "limit" => "1"
    }

    with {:ok, rows} <- request(tracker, :get, path, params: params),
         {:ok, row} <- first_row(rows, :tracker_item_not_found),
         true <- is_binary(row["roadmap_item_id"]) and row["roadmap_item_id"] != "",
         true <- is_binary(row["tenant_id"]) and row["tenant_id"] != "" do
      {:ok, row}
    else
      false -> {:error, :missing_tracker_context}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_loop_item_row(tracker, row) do
    path = "/rest/v1/loop_items"

    params = %{
      "select" => @loop_context_select,
      "roadmap_item_id" => "eq.#{row["roadmap_item_id"]}",
      "tenant_id" => "eq.#{row["tenant_id"]}",
      "order" => "updated_at.desc",
      "limit" => "1"
    }

    with {:ok, rows} <- request(tracker, :get, path, params: params),
         {:ok, loop_item} <- first_row(rows, :loop_item_not_found),
         true <- is_binary(loop_item["id"]) and loop_item["id"] != "" do
      {:ok, loop_item}
    else
      false -> {:error, :loop_item_not_found}
      {:error, :loop_item_not_found} ->
        Logger.warning("Supabase comment sink skipped: no loop item found for roadmap_item_id=#{row["roadmap_item_id"]}")
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_comment_event(_tracker, :ok, _issue_id, _comment_body), do: :ok

  defp write_comment_event(tracker, loop_context, issue_id, comment_body) when is_map(loop_context) do
    path = "/rest/v1/loop_events"

    payload = %{
      "tenant_id" => loop_context["tenant_id"],
      "loop_item_id" => loop_context["loop_item_id"],
      "decision_id" => loop_context["decision_id"],
      "roadmap_item_id" => loop_context["roadmap_item_id"],
      "insight_id" => loop_context["insight_id"],
      "actor_type" => "system",
      "event_type" => @comment_event_type,
      "event_summary" => comment_event_summary(comment_body),
      "metadata" => %{
        "source" => @comment_metadata_source,
        "tracker_item_id" => issue_id,
        "tracker_identifier" => loop_context["tracker_identifier"],
        "comment_body" => comment_body
      }
    }

    case request(tracker, :post, path, body: payload, headers: [{"prefer", "return=minimal"}]) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp touch_loop_item(_tracker, nil), do: :ok
  defp touch_loop_item(_tracker, ""), do: :ok
  defp touch_loop_item(_tracker, :ok), do: :ok

  defp touch_loop_item(tracker, loop_item_id) do
    path = "/rest/v1/loop_items"

    attrs = %{
      "last_event_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case request(
           tracker,
           :patch,
           path,
           params: %{"id" => "eq.#{loop_item_id}"},
           body: attrs,
           headers: [{"prefer", "return=minimal"}]
         ) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp first_row(rows, not_found_reason) when is_list(rows) do
    case rows do
      [row | _rest] when is_map(row) -> {:ok, row}
      _ -> {:error, not_found_reason}
    end
  end

  defp first_row(_rows, not_found_reason), do: {:error, not_found_reason}

  defp comment_event_summary(comment_body) do
    preview = String.slice(comment_body, 0, 140)

    cond do
      String.length(comment_body) <= 140 ->
        "Orchestrator comment: #{preview}"

      true ->
        "Orchestrator comment: #{preview}..."
    end
  end

  defp request(tracker, method, path, opts) do
    base_url = normalize_base_url(tracker.supabase_url)

    headers =
      [
        {"apikey", tracker.supabase_secret_key},
        {"authorization", "Bearer #{tracker.supabase_secret_key}"},
        {"content-type", "application/json"}
      ] ++ Keyword.get(opts, :headers, [])

    req_opts = [
      base_url: base_url,
      url: path,
      method: method,
      headers: headers,
      params: Keyword.get(opts, :params, %{}),
      decode_json: [keys: :strings]
    ]

    req_opts =
      case Keyword.fetch(opts, :body) do
        {:ok, body} -> Keyword.put(req_opts, :json, body)
        :error -> req_opts
      end

    request_fun = Application.get_env(:symphony_elixir, :supabase_request_fun, &Req.request/1)

    case request_fun.(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status, body: body}} ->
        {:error, {:supabase_api_status, status, body}}

      {:error, reason} ->
        {:error, {:supabase_api_request, reason}}
    end
  end

  defp normalize_base_url(url) when is_binary(url) do
    String.trim_trailing(url, "/")
  end

  defp validate_supabase_settings(tracker) do
    cond do
      not is_binary(tracker.supabase_url) ->
        {:error, :missing_supabase_url}

      not is_binary(tracker.supabase_secret_key) ->
        {:error, :missing_supabase_secret_key}

      true ->
        :ok
    end
  end

  defp in_filter(values) when is_list(values) do
    encoded_values =
      values
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.replace(&1, ",", "\\,"))
      |> Enum.join(",")

    "in.(#{encoded_values})"
  end
end
