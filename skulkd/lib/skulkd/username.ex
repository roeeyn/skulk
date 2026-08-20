defmodule Skulkd.Username do
  @moduledoc """
  Random connection-scoped usernames, `<adjective>-<animal>-<two digits>` (spec §6.4).

  Usernames are metadata, not identity: they are assigned by the relay, unique only
  among currently-connected members, and change on every reconnect. Nothing
  cryptographic depends on them.

  Amendment A12 (do not reuse a username that appears in retained history) is M1;
  M0 guarantees uniqueness among connected members only.
  """

  @adjectives ~w(
    quiet bright amber clever swift gentle hidden lucky nimble patient
    rustic silent sunny tidal velvet wandering zesty brave crisp dusky
    eager fabled glossy humble ivory jolly keen lively mellow noble
  )

  @animals ~w(
    otter fox heron lynx marten badger raven stoat vole weasel
    ferret marmot pika quokka tapir wombat gecko ibex jackal kestrel
    lemur numbat ocelot puffin quail rook serval tanuki urchin viper
  )

  @doc """
  A username not present in `taken`.

  The namespace is ~90,000 and spec §8 caps a room at 32 participants, so the retry
  loop is not a livelock risk. It is bounded anyway: an exhausted namespace should
  surface as an error, not a hung `GenServer`.
  """
  @spec generate(taken :: Enumerable.t()) :: {:ok, String.t()} | {:error, :no_username_available}
  def generate(taken \\ []) do
    taken = MapSet.new(taken)

    Enum.reduce_while(1..100, {:error, :no_username_available}, fn _, acc ->
      candidate = random()
      if MapSet.member?(taken, candidate), do: {:cont, acc}, else: {:halt, {:ok, candidate}}
    end)
  end

  defp random do
    digits = :rand.uniform(100) - 1

    "#{Enum.random(@adjectives)}-#{Enum.random(@animals)}-#{String.pad_leading(Integer.to_string(digits), 2, "0")}"
  end
end
