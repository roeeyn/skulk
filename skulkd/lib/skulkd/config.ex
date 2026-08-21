defmodule Skulkd.Config do
  @moduledoc """
  The relay's boot-time configuration, read from the environment.

  `config/runtime.exs` calls `from_env/1` and writes the result into application
  environment; `Skulkd.Limits` reads it back from there, unchanged. That is the
  whole mechanism.

  ## Why this is a module and not four lines in runtime.exs

  A config file is code no test can call. Everything interesting here is parsing
  operator input — the part most likely to be wrong and least likely to be
  noticed — so it lives in a pure function from an environment map to a keyword
  list, and `runtime.exs` becomes a two-line caller.

  ## Why environment variables at all

  Spec §7.4 spells this interface as flags on a `skulkd` binary. A container is
  configured by its environment, and §24 asks for an "example environment
  /configuration file", so the flags become variables until M5 packages the
  binary that can parse them. Recorded as entry #2 in
  [`docs/deviations.md`](../../../docs/deviations.md); the flag names survive as
  the variable names.

  ## Why a bad value stops the boot

  A relay that starts with a bound it could not parse is worse than one that
  refuses to start, because the operator believes a limit is in force. Every
  parse failure raises with the variable named and the value shown.

  There is nothing secret in this file's inputs — every one of them is a
  capacity number — so echoing a rejected value is safe. §18.2's rule about
  never printing secret material still applies to anything added later.
  """

  # Spec §7.4's flags, as environment variables. The mapping is public because
  # two tests read it: one asserts it covers every bound in `Skulkd.Limits`, the
  # other that `skulkd.env.example` documents every variable in it. Adding a
  # bound and forgetting either fails both.
  #
  # `--room-ttl` gains an `_MS` suffix. §7.4 spells it as a duration, and a
  # duration syntax is a small language with its own bugs ("120h", "5m", "1h30m")
  # for a value that is set once per deployment. Milliseconds, and the example
  # file does the arithmetic in a comment.
  @bounds %{
    room_ttl_ms: "SKULKD_ROOM_TTL_MS",
    max_rooms: "SKULKD_MAX_ROOMS",
    max_members_per_room: "SKULKD_MAX_MEMBERS_PER_ROOM",
    max_history_messages: "SKULKD_MAX_HISTORY_MESSAGES",
    max_history_bytes: "SKULKD_MAX_HISTORY_BYTES",
    max_total_history_bytes: "SKULKD_MAX_TOTAL_HISTORY_BYTES",
    max_member_backlog: "SKULKD_MAX_MEMBER_BACKLOG"
  }

  @bind "SKULKD_BIND"

  @doc "The bound-to-variable mapping. See the note above it."
  @spec bounds() :: %{atom() => String.t()}
  def bounds, do: @bounds

  @doc """
  Application-environment settings for the variables that are actually set.

  An unset variable produces nothing at all rather than its default: the
  defaults live in `Skulkd.Limits` and restating them here would put each one in
  two places, where they would eventually disagree.
  """
  @spec from_env(%{optional(String.t()) => String.t()}) :: keyword()
  def from_env(env) when is_map(env) do
    bounds =
      Enum.flat_map(@bounds, fn {key, variable} ->
        case Map.fetch(env, variable) do
          {:ok, value} -> [{key, positive_integer!(variable, value)}]
          :error -> []
        end
      end)

    case Map.fetch(env, @bind) do
      {:ok, value} ->
        {ip, port} = bind!(value)
        bounds ++ [ip: ip, port: port]

      :error ->
        bounds
    end
  end

  # ---------------------------------------------------------------------------

  defp positive_integer!(variable, value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 ->
        parsed

      _ ->
        raise ArgumentError, """
        #{variable} must be a positive integer, in the unit its name gives.

            #{variable}=#{inspect(value)}

        Digits only — no units, no separators, no leading sign. See \
        skulkd/skulkd.env.example, which spells out the arithmetic for each bound \
        in a comment.
        """
    end
  end

  # §7.4's `--bind <IP:PORT>`. IPv6 is bracketed, the way a URL writes it, which
  # is also what makes the last colon unambiguous.
  defp bind!("[" <> rest = value) do
    case String.split(rest, "]:", parts: 2) do
      [address, port] -> {address!(value, address), port!(value, port)}
      _ -> raise ArgumentError, bind_message(value)
    end
  end

  defp bind!(value) do
    case String.split(value, ":") do
      [address, port] -> {address!(value, address), port!(value, port)}
      _ -> raise ArgumentError, bind_message(value)
    end
  end

  defp address!(value, address) do
    case :inet.parse_address(String.to_charlist(address)) do
      {:ok, parsed} -> parsed
      {:error, _} -> raise ArgumentError, bind_message(value)
    end
  end

  defp port!(value, port) do
    case Integer.parse(port) do
      {parsed, ""} when parsed in 1..65_535 -> parsed
      _ -> raise ArgumentError, bind_message(value)
    end
  end

  defp bind_message(value) do
    """
    #{@bind} must be an address and a port, as `IP:PORT`.

        #{@bind}=#{inspect(value)}

    Examples:

        #{@bind}=0.0.0.0:4000      every interface — what a container wants
        #{@bind}=127.0.0.1:4000    loopback only — what a relay behind a TLS
                                   reverse proxy wants, so nothing else can reach it
        #{@bind}=[::]:4000         every interface, dual stack

    A hostname is not accepted: resolution at boot would make where the relay
    listens depend on DNS. IPv6 must be bracketed so the port's colon is the
    last one.
    """
  end
end
