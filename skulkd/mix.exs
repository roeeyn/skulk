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
  # :integration tag that test/test_helper.exs excludes from the fast loop.
  #
  # The Go client is built first, because this suite drives real `skulk --headless`
  # binaries through Ports — a stale binary would test yesterday's client against
  # today's relay and pass.
  defp aliases do
    ["test.integration": [&build_client/1, "test test/integration --include integration"]]
  end

  # CI builds the client itself and exports SKULK_BIN; locally we build on demand.
  defp build_client(_args) do
    case System.get_env("SKULK_BIN") do
      path when is_binary(path) and path != "" ->
        if File.exists?(path) do
          Mix.shell().info("skulk client: using SKULK_BIN at #{path}")
        else
          Mix.raise("SKULK_BIN is set to #{path}, but nothing is there")
        end

      _ ->
        root = Path.expand("..", __DIR__)
        target = Path.join([root, "bin", "skulk"])
        Mix.shell().info("skulk client: building #{target}")

        case System.cmd("go", ["build", "-o", target, "./cmd/skulk"],
               cd: root,
               stderr_to_stdout: true
             ) do
          {_output, 0} -> System.put_env("SKULK_BIN", target)
          {output, code} -> Mix.raise("go build failed (#{code}):\n#{output}")
        end
    end
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
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      # A raw WebSocket client for transport tests — raw on purpose: the corpus
      # contains frames no well-behaved client would ever send (ROJ-32).
      #
      # Not replaceable by Req: Req is built on Finch, and Finch is HTTP-only, so
      # nothing in that stack can perform a WebSocket upgrade. `mint` itself is
      # transitive from this, not a dependency we chose directly. The few plain HTTP
      # calls in the test suite reuse Mint rather than adding a second HTTP client.
      {:mint_web_socket, "~> 1.0", only: :test}
    ]
  end
end
