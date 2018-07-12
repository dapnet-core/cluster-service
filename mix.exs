defmodule Cluster.MixProject do
  use Mix.Project

  def project do
    [
      app: :cluster,
      version: "0.1.0",
      elixir: "~> 1.6",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      applications: [:cowboy, :plug, :httpoison, :amqp, :timex],
      extra_applications: [:logger],
      mod: {Cluster.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:cowboy, "~> 2.0"},
      {:plug, "~> 1.0"},
      {:amqp, "~> 1.0.3"},
      {:httpoison, "~> 1.1.1"},
      {:timex, "~> 3.1"},
      {:couchdb, github: "7h0ma5/elixir-couchdb"}
    ]
  end
end
