defmodule Skulkd.MixProject do
  use Mix.Project

  def project do
    [
      app: :skulkd,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  # `mix test.integration` runs only test/integration (ROJ-35), re-including the
  # :integration tag that test/test_helper.exs excludes from the fast loop. With no
  # integration tests yet it runs zero tests and exits 0 — which is what lets CI's
  # integration job be real before M0-7 exists.
  defp aliases do
    ["test.integration": ["test test/integration --include integration"]]
  end

  # Without this, `mix test.integration` would run in :dev and fail to find the suite.
  def cli do
    [preferred_envs: ["test.integration": :test]]
  end

  # Test-only fakes (Skulkd.Clock.Fake, Skulkd.Timer.Manual) compile into :test only.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Skulkd.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # HTTP server + WebSocket (the stack Phoenix itself sits on; no Phoenix — see
      # docs/designs/terminal-e2ee-chat.md A13: Channels/Presence deliberately excluded)
      {:bandit, "~> 1.6"},
      {:websock_adapter, "~> 0.5"},
      {:plug, "~> 1.16"},
      {:jason, "~> 1.4"},
      # M0 room passwords (same hashing phx.gen.auth uses)
      {:argon2_elixir, "~> 4.0"},
      # Property-based tests for frame validation (§22.3 / A14)
      {:stream_data, "~> 1.1", only: [:test, :dev]}
    ]
  end
end
