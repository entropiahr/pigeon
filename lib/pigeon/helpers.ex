defmodule Pigeon.Helpers do
  def merge_grouped_responses(responses) do
    Enum.reduce(responses, %{}, fn(rg, acc) ->
      case rg do
        {:ok, response_group} ->
          oks =
            with oks = acc[:ok] || [],
              new_oks = response_group[:ok] || []
            do
              oks ++ new_oks
            end
          errors =
            with errors =  acc[:error] || %{},
              new_errors = response_group[:error] || %{}
            do
              Enum.reduce(new_errors, errors, fn({key, value}, acc) ->
                similar = acc[key] || []
                Map.put(acc, key, similar ++ value)
              end)
            end
          acc
          |> Map.put(:error, errors)
          |> Map.put(:ok, oks)
        _ -> acc
      end
    end)
  end

  def group_responses(responses) do
    Enum.reduce(responses, %{}, fn(response, acc) ->
      case response do
        {:ok, r} -> update_result(acc, r)
        _ -> acc
      end
    end)
  end

  defp update_result(acc, response) do
    case response do
      {:ok, notif} -> add_ok_notif(acc, notif)
      {:error, reason, notif} -> add_error_notif(acc, reason, notif)
    end
  end

  defp add_ok_notif(acc, notif) do
    oks = acc[:ok] || []
    Map.put(acc, :ok, oks ++ [notif])
  end

  defp add_error_notif(acc, reason, notif) do
    errors = acc[:error] || %{}
    similar = errors[reason] || []
    errors = Map.put(errors, reason, similar ++ [notif])
    Map.put(acc, :error, errors)
  end
end
