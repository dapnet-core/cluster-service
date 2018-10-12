defmodule Cluster.RabbitMQ do
  use GenServer
  use AMQP
  require Logger

  def start_link do
    GenServer.start_link(__MODULE__, {}, [name: __MODULE__])
  end

  def publish_call(transmitter, data) do
    GenServer.call(__MODULE__, {:publish_call, transmitter, data})
  end

  def init(_opts) do
    Process.send_after(self(), :connect, 5000)
    {:ok, nil}
  end

  def handle_info(:connect, state) do
    name = System.get_env("NODE_NAME")
    auth_key = System.get_env("NODE_AUTHKEY")

    case Connection.open("amqp://node-#{name}:#{auth_key}@rabbitmq") do
      {:ok, conn} ->
        Logger.info("Connection to RabbitMQ successful.")

        {:ok, chan} = Channel.open(conn)

        Logger.info("Creating dapnet.calls exchange.")
        :ok = Exchange.fanout(chan, "dapnet.calls", durable: true)

        Logger.info("Creating dapnet.telemetry exchange.")
        :ok = Exchange.fanout(chan, "dapnet.telemetry", durable: true)

        Process.send_after(self(), :federation, 5000)

        {:noreply, chan}
      _ ->
        Logger.error("Could not connect to RabbitMQ.")
        Process.send_after(self(), :connect, 5000)
        {:noreply, nil}
    end
  end

  def handle_info(:federation, state) do
    Cluster.Discovery.reachable_nodes() |> Enum.each(fn {node, params} ->
      case federation_get(node) do
        {:ok, %HTTPoison.Response{status_code: 200}} ->
          Logger.debug("Federation with #{node} exists.")
        {:ok, %HTTPoison.Response{status_code: 404}} ->
          case federation_create(node, params["host"]) do
            {:ok, _} -> Logger.info("Creating federation to #{node}.")
            _ -> Logger.error("Failed to create federation to #{node}.")
          end
        {:error, %HTTPoison.Error{reason: reason}} ->
          Logger.error("Failed to query federation #{node}.")
      end
    end)

    case policy_get() do
      {:ok, %HTTPoison.Response{status_code: 200}} ->
        Logger.debug("DAPNET federation policy exists.")
      {:ok, %HTTPoison.Response{status_code: 404}} ->
        case policy_create() do
          {:ok, _} -> Logger.info("Creating DAPNET federation policy.")
          _ -> Logger.error("Failed to create DAPNET federation policy.")
        end
      {:error, %HTTPoison.Error{reason: reason}} ->
        Logger.error("Failed to query DAPNET federation policy.")
    end

    Process.send_after(self(), :federation, 60000)
    {:noreply, state}
  end

  def federation_create(node, host) do
    name = System.get_env("NODE_NAME")
    auth_key = System.get_env("NODE_AUTHKEY")

    url = "http://rabbitmq:15672/api/parameters/federation-upstream/%2f/#{node}"
    params = %{value: %{"uri": "amqp://node-#{name}:#{auth_key}@#{host}",
                        "expires": 3600000,
                        "max-hops": 3
                       }} |> Poison.encode!

    options = auth_options()
    HTTPoison.put(url, params, [], options)
  end

  def federation_delete(node) do
    url = "http://rabbitmq:15672/api/parameters/federation-upstream/%2f/#{node}"
    options = auth_options()
    HTTPoison.delete(url, [], options)
  end

  def federation_get(node) do
    url = "http://rabbitmq:15672/api/parameters/federation-upstream/%2f/#{node}"
    options = auth_options()
    HTTPoison.get(url, [], options)
  end

  def policy_create() do
    url = "http://rabbitmq:15672/api/policies/%2f/dapnet-federation"
    params = %{"pattern": "^dapnet\.(calls|telemetry)",
               "definition": %{"federation-upstream-set": "all"},
               "apply-to": "exchanges"
              } |> Poison.encode!

    options = auth_options()
    HTTPoison.put(url, params, [], options)
  end

  def policy_get() do
    url = "http://rabbitmq:15672/api/policies/%2f/dapnet-federation"
    options = auth_options()
    HTTPoison.get(url, [], options)
  end

  def auth_options() do
    name = System.get_env("NODE_NAME")
    auth_key = System.get_env("NODE_AUTHKEY")

    options = [hackney: [basic_auth: {"node-#{name}", auth_key}]]
  end

  def handle_call({:publish_call, transmitter, data}, _from, chan) do
    data = data |> Poison.encode!
    AMQP.Basic.publish chan, "dapnet.transmitters", transmitter <> ".call", data
    {:reply, {}, chan}
  end
end
