defmodule SymphonyElixir.Supabase.IssueMapper do
  @moduledoc false

  alias SymphonyElixir.Linear.Issue

  @spec from_row(map(), String.t() | nil) :: Issue.t() | nil
  def from_row(row, configured_assignee \\ nil)

  def from_row(row, configured_assignee) when is_map(row) do
    id = normalize_string(Map.get(row, "tracker_item_id"))
    identifier = normalize_string(Map.get(row, "tracker_identifier"))
    title = normalize_string(Map.get(row, "title"))
    state = normalize_string(Map.get(row, "state"))

    if is_binary(id) and is_binary(identifier) and is_binary(title) and is_binary(state) do
      %Issue{
        id: id,
        identifier: identifier,
        title: title,
        description: normalize_string(Map.get(row, "description")),
        priority: normalize_priority(Map.get(row, "priority")),
        state: state,
        assigned_to_worker:
          normalize_assigned_to_worker(
            Map.get(row, "assigned_to_worker"),
            normalize_string(configured_assignee)
          ),
        blocked_by: normalize_blocked_by(Map.get(row, "blocked_by")),
        created_at: parse_datetime(Map.get(row, "created_at")),
        updated_at: parse_datetime(Map.get(row, "updated_at")),
        labels: []
      }
    else
      nil
    end
  end

  def from_row(_row, _configured_assignee), do: nil

  @spec normalize_priority(term()) :: integer() | nil
  defp normalize_priority(priority) when is_integer(priority) and priority in 1..4, do: priority

  defp normalize_priority(priority) when is_binary(priority) do
    case String.downcase(String.trim(priority)) do
      "critical" -> 1
      "high" -> 2
      "medium" -> 3
      "low" -> 4
      _ -> nil
    end
  end

  defp normalize_priority(_priority), do: nil

  @spec normalize_assigned_to_worker(term(), String.t() | nil) :: boolean()
  defp normalize_assigned_to_worker(nil, _configured_assignee), do: true
  defp normalize_assigned_to_worker("", _configured_assignee), do: true

  defp normalize_assigned_to_worker(value, configured_assignee) when is_binary(value) do
    normalized = String.downcase(String.trim(value))

    cond do
      normalized in ["false", "0", "no"] ->
        false

      normalized in ["true", "1", "yes"] ->
        true

      is_binary(configured_assignee) ->
        String.downcase(configured_assignee) == normalized

      true ->
        true
    end
  end

  defp normalize_assigned_to_worker(value, _configured_assignee) when is_boolean(value), do: value
  defp normalize_assigned_to_worker(_value, _configured_assignee), do: true

  @spec normalize_blocked_by(term()) :: [map()]
  defp normalize_blocked_by(blocked_by) when is_list(blocked_by) do
    blocked_by
    |> Enum.filter(fn
      %{"state" => state} when is_binary(state) -> true
      _ -> false
    end)
  end

  defp normalize_blocked_by(_blocked_by), do: []

  @spec parse_datetime(term()) :: DateTime.t() | nil
  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  @spec normalize_string(term()) :: String.t() | nil
  defp normalize_string(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_string(_value), do: nil
end
