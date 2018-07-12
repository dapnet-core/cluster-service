defmodule Cluster.Replication do
  use GenServer
  require Logger

  @databases ["users", "transmitters", "rubrics", "nodes"]

  def start_link do
    GenServer.start_link(__MODULE__, [], [name: __MODULE__])
  end

  def init(_opts) do
    Process.send_after(self(), :update, 10000)
    {:ok, nil}
  end

  def handle_info(:update, state) do
    Cluster.Discovery.reachable_nodes()
    |> Enum.filter(fn {_, params} -> Map.get(params, "couchdb") != nil end)
    |> Enum.each(fn {node, params} -> Cluster.CouchDB.sync_with(node, params) end)

    Process.send_after(self(), :update, 60000)
    {:noreply, state}
  end
end
