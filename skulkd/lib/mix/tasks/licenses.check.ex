defmodule Mix.Tasks.Licenses.Check do
  @shortdoc "Fails unless every dependency's license is on the allowlist"

  @moduledoc """
  Spec §22.3: *"Run dependency vulnerability and license checks in CI."*

  This is the license half, for Elixir. `mix deps.audit` (mix_audit) is the
  vulnerability half; `govulncheck` and `go-licenses` are the Go halves.

  ## Why this is thirty lines rather than a dependency

  Hex packages declare their licenses in their own metadata, and `mix deps.get`
  has already written that metadata to disk: every fetched dependency has a
  `hex_metadata.config`, which is Erlang terms, which `:file.consult/1` reads.
  So the check is a directory walk and a set membership test. Pulling in a
  license-scanning library to do that would add a dependency to the tree the
  tool exists to inspect, and §27 asks for explicit readable code over
  generalized frameworks.

  The Go side is not so lucky — Go modules carry no license metadata, so
  licenses there have to be *classified* by reading LICENSE files, which is a
  real problem and `go-licenses` is the tool for it.

  ## What counts as a failure

  Three things, and the second is the one worth having:

  1. A license that is not on the allowlist.
  2. **A dependency with no license metadata at all.** An unlicensed dependency
     is not a permissive one; a checker that only looks for known-bad strings
     passes it silently, which is the failure mode this check exists to avoid.
  3. A dependency declaring *several* licenses where any one of them is not
     allowed. Deliberately strict: dual licensing is usually an offer, and
     choosing which offer to accept is a decision a person should make on
     purpose rather than a tool should make quietly.

  A fourth thing that looks like a failure and is not quite one: Hex's `licenses`
  field is free text, so the same license reaches this check under more than one
  spelling. See `@allowed`.

  ## Changing the allowlist

  It is `@allowed` below, and it currently matches what the tree actually
  contains rather than what might be tolerable. Widening it should be a commit
  of its own, with a reason in the message.

      mix licenses.check
  """

  use Mix.Task

  # Every license present in the dependency tree today. Not a wish list.
  #
  # These are SPELLINGS, not SPDX identifiers, because Hex's `licenses` field is
  # free text that nothing validates — `yamerl` says "BSD 2-Clause" where
  # `comeonin` says "BSD-3-Clause", and both are correct as far as Hex is
  # concerned. Normalising would mean guessing, and a normaliser that works most
  # of the time turns a license check into a coin flip. So the allowlist holds
  # the exact strings, and an unfamiliar spelling of an acceptable license shows
  # up as a failure that a person resolves once.
  @allowed [
    "Apache-2.0",
    "BSD-3-Clause",
    "MIT",
    # yamerl, transitively through mix_audit -> yaml_elixir.
    "BSD 2-Clause"
  ]

  @impl Mix.Task
  def run(_args) do
    dependencies = fetched_dependencies()

    if dependencies == [] do
      Mix.raise("no dependencies are fetched — run `mix deps.get` first")
    end

    checked = Enum.map(dependencies, &{Path.basename(&1), licenses(&1)})

    for {name, licenses} <- checked do
      Mix.shell().info("  #{String.pad_trailing(name, 22)} #{describe(licenses)}")
    end

    case Enum.reject(checked, fn {_name, licenses} -> allowed?(licenses) end) do
      [] ->
        Mix.shell().info(
          "\n#{length(checked)} dependencies, every license on the allowlist " <>
            "(#{Enum.join(@allowed, ", ")})."
        )

      offenders ->
        Mix.raise("""
        Dependency licenses outside the allowlist (#{Enum.join(@allowed, ", ")}):

        #{Enum.map_join(offenders, "\n", fn {name, licenses} -> "  #{name}: #{describe(licenses)}" end)}

        Either drop the dependency or widen @allowed in lib/mix/tasks/licenses.check.ex
        — as a deliberate commit, with the reason in the message. skulk is MIT
        (see LICENSE), and a copyleft dependency in the tree is a licensing
        change to the whole project rather than a build failure to silence.
        """)
    end
  end

  # ---------------------------------------------------------------------------

  defp fetched_dependencies do
    Mix.Project.deps_path()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.filter(&File.dir?/1)
    |> Enum.sort()
  end

  # Hex writes this file on fetch; a git or path dependency has no such thing,
  # which is exactly the case that must fail rather than pass.
  defp licenses(path) do
    with {:ok, terms} <- :file.consult(Path.join(path, "hex_metadata.config")),
         {"licenses", declared} <- List.keyfind(terms, "licenses", 0) do
      {:ok, declared}
    else
      _ -> :undeclared
    end
  end

  defp allowed?({:ok, [_ | _] = declared}), do: Enum.all?(declared, &(&1 in @allowed))
  defp allowed?(_), do: false

  defp describe({:ok, []}), do: "declares an EMPTY license list"
  defp describe({:ok, declared}), do: Enum.join(declared, " AND ")
  defp describe(:undeclared), do: "NO license metadata"
end
