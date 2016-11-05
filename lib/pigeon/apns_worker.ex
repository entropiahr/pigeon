defmodule Pigeon.APNSWorker do
  @moduledoc """
    Handles all APNS request and response parsing over an HTTP2 connection.
  """
  use GenServer
  require Logger

  defp apns_production_api_uri, do: "api.push.apple.com"
  defp apns_development_api_uri, do: "api.development.push.apple.com"

  def push_uri(mode) do
    case mode do
      :dev -> apns_development_api_uri
      :prod -> apns_production_api_uri
    end
  end

  def start_link(config) do
    GenServer.start_link(__MODULE__, {:ok, config}, [])
  end

  def stop, do: :gen_server.cast(self, :stop)

  def init({:ok, config}), do: initialize_worker(config)

  def ping(socket) do
    Kadabra.ping(socket)
    receive do
      something -> something |> inspect |> Logger.debug
		after 5_000 ->
			Logger.debug "¯\_(ツ)_/¯"
    end
  end

  def initialize_worker(config) do
    mode = config[:mode]
    case connect_socket(config, 0) do
      {:ok, socket} ->
        Logger.debug "Started worker #{inspect(self)}"

        {:ok, %{
          apns_socket: socket,
          mode: mode,
          config: config,
          stream_id: 1,
          queue: %{}
        }}
      {:closed, socket} -> 
        Logger.error """
          Socket closed unexpectedly.
          """
        {:stop, {:error, :bad_connection}}
      {:error, :timeout} ->
        Logger.error """
          Failed to establish SSL connection. Is the certificate signed for :#{mode} mode?
          """
        {:stop, {:error, :timeout}}
      {:error, :invalid_config} ->
        Logger.error """
          Invalid configuration.
          """
        {:stop, {:error, :invalid_config}}
    end
  end

  def connect_socket(_config, 3), do: {:error, :timeout}
  def connect_socket(config, tries) do
    uri = config[:mode] |> push_uri |> to_char_list
    case connect_socket_options(config) do
      {:ok, options} -> do_connect_socket(config, uri, options, tries)
      error -> error
    end
  end

  def connect_socket_options(config) do
    cert = get_opt(config, :cert, :certfile)
    key = get_opt(config, :key, :keyfile)
    cond do
      cert && key ->
        options =
          [cert,
          key,
          {:password, ''},
          {:packet, 0},
          {:reuseaddr, true},
          {:active, true},
          :binary]
          |> optional_add_2197(config)
        {:ok, options}
      true ->
        {:error, :invalid_config}
    end
  end

  defp optional_add_2197(options, config) do
    case config[:use_2197] do
      true -> options ++ [{:port, 2197}]
      _ -> options
    end
  end

  defp get_opt(config, key_1, key_2) do
    cond do
      config[key_1] -> {key_1, config[key_1]}
      config[key_2] -> {key_2, config[key_2]}
      true -> nil
    end
  end

  defp do_connect_socket(config, uri, options, tries) do
    case Kadabra.open(uri, :https, options) do
      {:ok, socket} -> {:ok, socket}
      {:error, reason} ->
        Logger.error(inspect(reason))
        connect_socket(config, tries + 1)
    end
  end

  def handle_cast(:ping, state) do
    ping(state.apns_socket)
    { :noreply, state }
  end

  def handle_cast(:stop, state), do: { :noreply, state }

  def handle_cast({:push, :apns, notification}, state) do
    send_push(state, notification, nil)
  end

  def handle_cast({:push, :apns, notification, on_response}, state) do
    send_push(state, notification, on_response)
  end

  def send_push(state, notification, on_response) do
    %{apns_socket: socket, stream_id: stream_id, queue: queue} = state
    json = Pigeon.Notification.json_payload(notification.payload)
    req_headers = [
      {":method", "POST"},
      {":path", "/3/device/#{notification.device_token}"},
      {"content-length", "#{byte_size(json)}"}]
      |> put_apns_id(notification)
      |> put_apns_topic(notification)

    Kadabra.request(socket, req_headers, json)
    new_q = Map.put(queue, "#{stream_id}", {notification, on_response})
    new_stream_id = stream_id + 2
    { :noreply, %{state | stream_id: new_stream_id, queue: new_q } }
  end

  defp put_apns_id(headers, notification) do
    case notification.id do
      nil -> headers
      id -> headers ++ [{"apns-id", id}]
    end
  end

  defp put_apns_topic(headers, notification) do
    case notification.topic do
      nil   -> headers
      topic -> headers ++ [{"apns-topic", topic}]
    end
  end

  defp parse_error(data) do
    {:ok, response} = Poison.decode(data)
    response["reason"] |> Macro.underscore |> String.to_existing_atom
  end

  defp log_error(reason, notification) do
    Logger.error("#{reason}: #{error_msg(reason)}\n#{inspect(notification)}")
  end

  def error_msg(error) do
    case error do
      :payload_empty ->
        "The message payload was empty."
      :payload_too_large ->
        "The message payload was too large. The maximum payload size is 4096 bytes."
      :bad_topic ->
        "The apns-topic was invalid."
      :topic_disallowed ->
        "Pushing to this topic is not allowed."
      :bad_message_id ->
        "The apns-id value is bad."
      :bad_expiration_date ->
        "The apns-expiration value is bad."
      :bad_priority ->
        "The apns-priority value is bad."
      :missing_device_token ->
        """
        The device token is not specified in the request :path. Verify that the :path header
        contains the device token.
        """
      :bad_device_token ->
        """
        The specified device token was bad. Verify that the request contains a valid token and
        that the token matches the environment.
        """
      :device_token_not_for_topic ->
        "The device token does not match the specified topic."
      :unregistered ->
        "The device token is inactive for the specified topic."
      :duplicate_headers ->
        "One or more headers were repeated."
      :bad_certificate_environment ->
        "The client certificate was for the wrong environment."
      :bad_certificate ->
        "The certificate was bad."
      :forbidden ->
        "The specified action is not allowed."
      :bad_path ->
        "The request contained a bad :path value."
      :method_not_allowed ->
        "The specified :method was not POST."
      :too_many_requests ->
        "Too many requests were made consecutively to the same device token."
      :idle_timeout ->
        "Idle time out."
      :shutdown ->
        "The server is shutting down."
      :internal_server_error ->
        "An internal server error occurred."
      :service_unavailable ->
        "The service is unavailable."
      :missing_topic ->
          """
          The apns-topic header of the request was not specified and was required. The apns-topic
          header is mandatory when the client is connected using a certificate that supports
          multiple topics.
          """
      :timeout ->
        "The SSL connection timed out."
    end
  end

  def handle_info({:end_stream, %Kadabra.Stream{id: stream_id,
                                                headers: headers,
                                                body: body} = stream}, 
                                                %{apns_socket: socket, queue: queue} = state) do

    {notification, on_response} = queue["#{stream_id}"]

    case get_status(headers) do
      "200" ->
        notification = %{notification | id: get_apns_id(headers)}
        unless on_response == nil do on_response.({:ok, notification}) end
        new_queue = Map.delete(queue, "#{stream_id}")
        {:noreply, %{state | queue: new_queue}}
      nil ->
        {:noreply, state}
      _error ->
        reason = parse_error(body)
        log_error(reason, notification)
        unless on_response == nil do on_response.({:error, reason, notification}) end
        new_queue = Map.delete(queue, "#{stream_id}")
        {:noreply, %{state | queue: new_queue}}
    end
  end

  def handle_info(whatever, state) do
    Logger.debug(inspect(whatever))
    {:noreply, state}
  end

  def handle_cast(whatever, state) do
    Logger.debug(inspect(whatever))
    {:noreply, state}
  end

  defp get_status(headers) do
    case Enum.find(headers, fn({key, _val}) -> key == ":status" end) do
      {":status", status} -> status
      nil -> nil
    end
  end

  defp get_apns_id(headers) do
    case Enum.find(headers, fn({key, _val}) -> key == "apns-id" end) do
      {"apns-id", id} -> id
      nil -> nil
    end
  end
end
