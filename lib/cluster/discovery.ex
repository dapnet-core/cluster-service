defmodule Cluster.Discovery do
  use GenServer
  require Logger

  def nodes, do: GenServer.call(__MODULE__, :nodes)
  def reachable_nodes, do: GenServer.call(__MODULE__, :reachable_nodes)

  def start_link do
    GenServer.start_link(__MODULE__, [], [name: __MODULE__])
  end

  def init(_opts) do
    Process.send_after(self(), :update, 1000)

    name = System.get_env("NODE_NAME")

    nodes = Application.get_env(:cluster, __MODULE__)[:seed]
    |> Enum.filter(fn {node, _} -> node != name end)
    |> Enum.map(fn {node, params} -> {node,
         Map.merge(params, %{"last_seen" => nil, "reachable" => false})}
       end)
    |> Map.new

    Logger.info("Initial node list: #{inspect nodes}")

    {:ok, nodes}
  end

  def handle_info(:update, nodes) do
    Logger.info("Starting node discovery.")
    body = %{
      name: System.get_env("NODE_NAME"),
      auth_key: System.get_env("NODE_AUTH_KEY")
    } |> Poison.encode!

    Enum.map(nodes, fn {node, params} ->
      host = params["host"]
      task = Task.async(fn ->
      case HTTPoison.post("#{host}/cluster/discovery", body, [], [
                recv_timeout: 3000,
                timeout: 3000
              ]) do
        {:ok, response} ->
          case Poison.decode(response.body) do
            {:ok, data} -> node_data = Map.get(data, node)
            if node_data do
              Logger.info("Reached #{node}!")
              IO.inspect node_data
              {node, node_data}
            else
              Logger.warn("Could not read response from #{node}!")
              {node, %{params | "reachable" => false}}
            end
            _ ->
              Logger.warn("Could not decode response from #{node}!")
              {node, %{params | "reachable" => false}}
          end
        _ ->
          Logger.warn("Could not reach #{node}!")
          {node, %{params | "reachable" => false}}
      end
    end)
    end)

    Process.send_after(self(), :update, 60000)
    {:noreply, nodes}
  end

  def handle_info({ref, result}, nodes) when is_reference(ref) do
    {node, params} = result
    nodes = Map.put(nodes, node, params)

    {:noreply, nodes}
  end


  def handle_info({:DOWN, ref, proc, pid, shutdown}, nodes) when is_reference(ref) do
    {:noreply, nodes}
  end

  def handle_call(:nodes, _from, nodes) do
    name = System.get_env("NODE_NAME")

    nodes = nodes |> Map.put(name, %{
      "host" => System.get_env("NODE_HOSTNAME"),
      "reachable" => true,
      "last_seen" => Timex.now(),
      "couchdb" => %{
        "user" => System.get_env("COUCHDB_USER"),
        "password" => System.get_env("COUCHDB_PASSWORD"),
      }
    })

    {:reply, nodes, nodes}
  end

  def handle_call(:reachable_nodes, _from, nodes) do
    reachable_nodes = nodes
    |> Enum.filter(fn {_, params} -> Map.get(params, "reachable") end)

    {:reply, reachable_nodes, nodes}
  end
end
