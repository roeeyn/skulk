defmodule Skulkd.SelfHostingDocTest do
  @moduledoc """
  ROJ-50: `docs/self-hosting.md` is a §24 deliverable, and two of the things it
  must say are requirements rather than editorial choices.

  A document is the one part of a repository nothing checks. These are the
  sentences whose absence would be a spec violation or a reader walking into
  something SECURITY.md warns about, so they get the same treatment as the
  pinned-version claim in `Skulkd.SecurityDocTest`.
  """
  use ExUnit.Case, async: true

  alias Skulkd.Config

  @self_hosting Path.expand("../../../docs/self-hosting.md", __DIR__)
  @deviations Path.expand("../../../docs/deviations.md", __DIR__)

  @external_resource @self_hosting
  @external_resource @deviations

  defp self_hosting, do: File.read!(@self_hosting)

  test "it shows a wss:// deployment configuration (§7.4)" do
    # §7.4, verbatim: "Production documentation MUST show a `wss://` deployment
    # configuration." Not a mention of the scheme — a configuration, meaning
    # something to terminate TLS with and a client invocation that uses it.
    document = self_hosting()

    assert document =~ ~r/wss:\/\//,
           "§7.4 requires production documentation to show a wss:// deployment"

    assert document =~ ~r/reverse_proxy|proxy_pass/,
           "a wss:// deployment needs something in front of the relay to terminate TLS"

    assert document =~ ~r/--server\s+wss:\/\//,
           "show the client invocation too — the scheme is what the client checks"
  end

  test "it carries §19's no-rate-limiting warning where a reader cannot miss it" do
    # This document teaches people to expose a relay that SECURITY.md tells them
    # not to expose. If it does not carry the warning, it is an instruction to
    # walk into the thing the rest of the repository is careful about.
    #
    # "Where a reader cannot miss it" is enforced as: in the first quarter of the
    # document, before any deployment instruction.
    document = self_hosting()
    opening = String.slice(document, 0, div(String.length(document), 4))

    assert opening =~ ~r/no rate limiting/i,
           "§19's consequence belongs at the TOP of self-hosting.md, not in a footnote"

    assert opening =~ ~r/reads every message|not end-to-end encrypted/i,
           "a deployment guide that omits what the relay can read is a sales page"

    assert document =~ ~r/never been audited/i
  end

  test "the variable table names every bound the relay actually reads" do
    # The table restates skulkd.env.example, so it can fall behind it. Adding a
    # bound now fails three tests: this one, the mapping-coverage test, and the
    # example-file test.
    document = self_hosting()

    for variable <- Map.values(Config.bounds()) ++ ["SKULKD_BIND"] do
      assert document =~ variable,
             """
             docs/self-hosting.md does not mention #{variable}.

             Its configuration table is the first place a deployer looks. A bound \
             missing from it is a bound nobody sets.
             """
    end
  end

  test "§27's deviations file exists and has an entry" do
    # §27: "Record every unavoidable deviation from this specification in
    # docs/deviations.md before implementing it." A file that exists but is empty
    # satisfies the letter and none of the point.
    assert File.exists?(@deviations)

    deviations = File.read!(@deviations)

    assert deviations =~ ~r/^## 1\. /m, "deviations.md has no entry #1"
    assert deviations =~ ~r/\*\*Recorded\*\*/, "an entry with no date cannot be read as 'before'"
    assert deviations =~ ~r/\*\*Ends\*\*/, "a deviation with no expiry is a fork of the spec"
  end
end
