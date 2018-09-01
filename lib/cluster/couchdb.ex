defmodule Cluster.CouchDB do
  use GenServer, shutdown: 5000
  require Logger

  @mgmt_databases ["_users", "_replicator", "_global_changes"]
  @databases ["users", "transmitters", "subscribers", "rubrics", "nodes"]

  def sync_with(node, params), do: GenServer.cast(__MODULE__, {:sync_with, node, params})
  def db(name), do: GenServer.call(__MODULE__, {:db, name})
  def auth(node, auth_key), do: GenServer.call(__MODULE__, {:auth, node, auth_key})

  def start_link() do
    GenServer.start_link(__MODULE__, {}, [name: __MODULE__])
  end

  def init(args) do
    user = System.get_env("COUCHDB_USER")
    pass = System.get_env("COUCHDB_PASSWORD")
    server = CouchDB.connect("couchdb", 5984, "http", user, pass)
    Process.send_after(self(), :migrate, 5000)
    {:ok, server}
  end

  def handle_info(:migrate, server) do
    Logger.info("Creating CouchDB databases if necessary.")

    results = Enum.concat([@databases, @mgmt_databases])
    |> Enum.map(fn name ->
      database = server |> CouchDB.Server.database(name)
      {name, CouchDB.Database.create database}
    end)

    errors = Enum.filter(results, &match?({_, {:error, _}}, &1))
    |> Enum.map(fn {db, {:error, reason}} -> {db, Poison.decode!(reason)} end)
    |> Enum.filter(fn {_, %{"error" => error}} ->
      error != "file_exists"
    end)
    |> Enum.map(fn {db, error} ->
      Logger.error("Failed to create database #{db}: #{error}")
      true
    end)

    if !Enum.empty?(errors) do
      Logger.error("Failed to connect to CouchDB.")
      Process.send_after(self(), :migrate, 10000)
    else
      Enum.each(@databases, fn db ->
        database = CouchDB.Server.database(server, db)
        update_design_doc(db, database)
      end)
    end

    {:noreply, server}
  end

  def handle_cast({:sync_with, node, params}, server) do
    Logger.info("Sync CouchDB with #{node}")

    host = params["host"]
    user = params["couchdb"]["user"]
    auth_key = params["couchdb"]["password"]

    @databases
    |> Enum.each(fn db ->
      local_url = CouchDB.Server.url(server, "/#{db}")
      remote_url = "http://#{user}:#{auth_key}@#{host}:5984/#{db}"

      options = [create_target: false, continuous: true]

      result = CouchDB.Server.replicate(server, remote_url, local_url, options)

      Logger.debug "Replication status: #{inspect remote_url}"
    end)

    {:noreply, server}
  end

  def handle_call({:db, name}, _from, server) do
    {:reply, CouchDB.Server.database(server, name), server}
  end

  def handle_call({:auth, name, auth_key}, _from, server) do
    case get_node(name, server) do
      {:ok, node} ->
        if auth_key == Map.get(node, "auth_key") do
          {:reply, true, server}
        else
          {:reply, false, server}
        end
      _ ->
        {:reply, false, server}
    end
  end

  defp update_design_doc(name, database) do
    Logger.info "Updating design document for #{name}"

    new_doc = Path.join(:code.priv_dir(:cluster), "#{name}.json") |> File.read!
    |> String.replace("\n", "")
    |> Poison.decode!

    new_version = new_doc |> Map.get("version")

    current_doc = case database |> CouchDB.Database.get("_design/#{name}") do
                    {:ok, result} -> result |> Poison.decode!
                    {:error, _} -> nil
                  end

    current_version = if current_doc do
      current_doc |> Map.get("version", 0)
    else
      -1
    end

    result = cond do
      new_version == current_version ->
        Logger.info "Design document is up to date (v#{current_version})"
        nil
      new_version < current_version ->
        Logger.error "Design document is newer than internal (v#{current_version} > v#{new_version})"
        Logger.error "This version of the Cluster service is too old to handle the selected database"
        nil
      current_doc ->
        Logger.info "Updating the design document from v#{current_version} to v#{new_version}..."
        rev = current_doc |> Map.get("_rev")
        new_doc = new_doc |> Map.put("_rev", rev)
        database |> CouchDB.Database.insert(Poison.encode!(new_doc))
      true ->
        Logger.info "Creating the design document (v#{new_version})..."
        database |> CouchDB.Database.insert(Poison.encode!(new_doc))
    end

    case result do
      {:ok, _} -> Logger.info "Database successfully updated"
      {:error, _} -> Logger.warn "Database update failed"
      _ -> ()
    end
  end

  defp get_node(name, server) do
    db = server |> CouchDB.Server.database("nodes")
    result = CouchDB.Database.get(db, String.downcase(name))

    case result do
      {:ok, data} ->
        Poison.decode(data)
      _ ->
        {:error, :not_found}
    end
  end
end
