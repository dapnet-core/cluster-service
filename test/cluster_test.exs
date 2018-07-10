defmodule ClusterTest do
  use ExUnit.Case
  doctest Cluster

  test "greets the world" do
    assert Cluster.hello() == :world
  end
end
