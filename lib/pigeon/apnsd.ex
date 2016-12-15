defmodule Pigeon.APNSD do
  require Logger
  import Supervisor.Spec

  @default_timeout 5_000

  def push(notifications, opts)  when is_list(notifications) do
    case ensure_worker(opts) do
      {:ok, worker_pid} ->
        case opts[:on_response] do
          nil ->
            tasks = for n <- notifications, do: Task.async(fn -> do_sync_push(worker_pid, n) end)
            tasks
            |> Task.yield_many(@default_timeout + 500)
            |> Enum.map(fn {task, response} -> response || Task.shutdown(task, :brutal_kill) end)
            |> Pigeon.Helpers.group_responses()
          on_response -> push(worker_pid, notifications, on_response)
        end
      {:error, error} ->
        %{error: %{error => notifications}}
    end
  end

  def push(notification, opts) do
    if worker_pid = ensure_worker(opts[:cert]) do
      case opts[:on_response] do
        nil -> do_sync_push(worker_pid, notification)
        on_response -> push(worker_pid, notification, on_response)
      end
    else
      %{error: %{missing_certificate: notification}}
    end
  end

  def push(worker_pid, notifications, on_response) when is_list(notifications) do
    for n <- notifications, do: push(worker_pid, n, on_response)
  end
  def push(worker_pid, notification, on_response) do
    GenServer.cast(worker_pid, {:push, :apns, notification, on_response})
  end

  def do_sync_push(worker_pid, notification) do
    pid = self
    on_response = fn(x) -> send pid, {:ok, x} end
    GenServer.cast(worker_pid, {:push, :apns, notification, on_response})

    receive do
      {:ok, x} -> x
    after
      @default_timeout -> {:error, :timeout, notification}
    end
  end

  def ensure_worker(opts = %{cert: cert}) do
    mode = opts[:mode] || Application.get_env(:pigeon, :env, :dev)

    worker_name =
      :crypto.hash(:sha, cert)
      |> Base.encode16()
      |> Kernel.<> mode

    worker_name
    |> String.to_atom()
    |> GenServer.whereis()
    case do
      :nil ->
        case :public_key.pem_decode(cert) do
          [{:Certificate, cert_der, _},
           {:PrivateKeyInfo, key_der, _}
          ] ->
            config =
              %{name: worker_name,
                mode: mode,
                key: {:PrivateKeyInfo, key_der},
                keyfile: :nil,
                cert: cert_der,
                certfile: :nil,
                dynamic: true
              }

            Supervisor.start_child(Pigeon.APNSD.Supervisor, [config])
          _ -> {:error, :invalid_certificate}
      pid ->
        {:ok, pid}
    end
  end

  def ensure_worker(_opts), do: {:error, :missing_certificate}
end

defmodule Pigeon.APNSD.Supervisor do
  use Supervisor

  def start_link do
    Supervisor.start_link(__MODULE__, [], [name: __MODULE__])
  end

  def init([]) do
    children = [ worker(Pigeon.APNSWorker, [], restart: :transient) ]
    supervise(children, strategy: :simple_one_for_one)
  end
end
