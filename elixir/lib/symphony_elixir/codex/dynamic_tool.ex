defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Linear.Client, Tracker}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @supabase_update_state_tool "supabase_update_state"
  @supabase_update_state_description """
  Update the state of the current roadmap item in Supabase.
  Use this to transition the item to Human Review, Rework, Done, or any other valid state.
  Only available when Symphony is running with tracker.kind = "supabase".
  """
  @supabase_update_state_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "state"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "The UUID of the roadmap item to update (tracker_item_id from the issue context)."
      },
      "state" => %{
        "type" => "string",
        "description" => "Target state name. Valid values: In Progress, Human Review, Rework, Merging, Done, Closed."
      }
    }
  }

  @supabase_set_pr_url_tool "supabase_set_pr_url"
  @supabase_set_pr_url_description """
  Record the GitHub PR URL for this roadmap item in Supabase.
  Call this immediately after opening a PR (before moving to Human Review).
  This triggers an inbox notification so the team can review and approve the build.
  Only available when Symphony is running with tracker.kind = "supabase".
  """
  @supabase_set_pr_url_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["issue_id", "pr_url"],
    "properties" => %{
      "issue_id" => %{
        "type" => "string",
        "description" => "The UUID of the roadmap item (tracker_item_id from the issue context)."
      },
      "pr_url" => %{
        "type" => "string",
        "description" => "The full GitHub PR URL, e.g. https://github.com/org/repo/pull/42"
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @supabase_update_state_tool ->
        execute_supabase_update_state(arguments)

      @supabase_set_pr_url_tool ->
        execute_supabase_set_pr_url(arguments)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    base = [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      }
    ]

    # Add supabase tools only when running in supabase tracker mode
    case tracker_kind() do
      "supabase" ->
        base ++
          [
            %{
              "name" => @supabase_update_state_tool,
              "description" => @supabase_update_state_description,
              "inputSchema" => @supabase_update_state_input_schema
            },
            %{
              "name" => @supabase_set_pr_url_tool,
              "description" => @supabase_set_pr_url_description,
              "inputSchema" => @supabase_set_pr_url_input_schema
            }
          ]

      _ ->
        base
    end
  end

  defp execute_supabase_update_state(arguments) when is_map(arguments) do
    issue_id = Map.get(arguments, "issue_id") || Map.get(arguments, :issue_id)
    state = Map.get(arguments, "state") || Map.get(arguments, :state)

    cond do
      tracker_kind() != "supabase" ->
        failure_response(%{
          "error" => %{
            "message" => "supabase_update_state is only available when tracker.kind is \"supabase\"."
          }
        })

      not is_binary(issue_id) or String.trim(issue_id) == "" ->
        failure_response(%{
          "error" => %{"message" => "issue_id must be a non-empty string."}
        })

      not is_binary(state) or String.trim(state) == "" ->
        failure_response(%{
          "error" => %{"message" => "state must be a non-empty string."}
        })

      true ->
        case Tracker.update_issue_state(String.trim(issue_id), String.trim(state)) do
          :ok ->
            %{
              "success" => true,
              "output" => "State updated to \"#{state}\" for issue #{issue_id}.",
              "contentItems" => [
                %{"type" => "inputText", "text" => "State updated to \"#{state}\" for issue #{issue_id}."}
              ]
            }

          {:error, reason} ->
            failure_response(%{
              "error" => %{
                "message" => "Failed to update state to \"#{state}\" for issue #{issue_id}.",
                "reason" => inspect(reason)
              }
            })
        end
    end
  end

  defp execute_supabase_update_state(_arguments) do
    failure_response(%{
      "error" => %{
        "message" => "supabase_update_state expects an object with issue_id and state fields."
      }
    })
  end

  defp execute_supabase_set_pr_url(arguments) when is_map(arguments) do
    issue_id = Map.get(arguments, "issue_id") || Map.get(arguments, :issue_id)
    pr_url = Map.get(arguments, "pr_url") || Map.get(arguments, :pr_url)

    cond do
      tracker_kind() != "supabase" ->
        failure_response(%{
          "error" => %{
            "message" => "supabase_set_pr_url is only available when tracker.kind is \"supabase\"."
          }
        })

      not is_binary(issue_id) or String.trim(issue_id) == "" ->
        failure_response(%{
          "error" => %{"message" => "issue_id must be a non-empty string."}
        })

      not is_binary(pr_url) or String.trim(pr_url) == "" ->
        failure_response(%{
          "error" => %{"message" => "pr_url must be a non-empty string."}
        })

      true ->
        case Tracker.set_pr_url(String.trim(issue_id), String.trim(pr_url)) do
          :ok ->
            %{
              "success" => true,
              "output" => "PR URL recorded for issue #{issue_id}: #{pr_url}",
              "contentItems" => [
                %{"type" => "inputText", "text" => "PR URL recorded: #{pr_url}"}
              ]
            }

          {:error, reason} ->
            failure_response(%{
              "error" => %{
                "message" => "Failed to record PR URL for issue #{issue_id}.",
                "reason" => inspect(reason)
              }
            })
        end
    end
  end

  defp execute_supabase_set_pr_url(_arguments) do
    failure_response(%{
      "error" => %{
        "message" => "supabase_set_pr_url expects an object with issue_id and pr_url fields."
      }
    })
  end

  defp tracker_kind do
    try do
      Config.settings!().tracker.kind
    rescue
      _ -> nil
    end
  end


  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
