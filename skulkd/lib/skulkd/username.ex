defmodule Skulkd.Username do
  @moduledoc """
  Random connection-scoped usernames, `<adjective>-<animal>-<two digits>` (spec §6.4).

  Usernames are metadata, not identity: they are assigned by the relay, unique only
  among currently-connected members, and change on every reconnect. Nothing
  cryptographic depends on them.

  Amendment A12 — do not reuse a username that appears in retained history — is
  enforced by the caller: this module avoids whatever set it is given, and
  `Skulkd.Room` is what decides that the set includes the senders of retained
  messages as well as the members currently connected.
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

  @doc "The adjectives half of the namespace."
  @spec adjectives() :: [String.t()]
  def adjectives, do: @adjectives

  @doc "The animals half of the namespace."
  @spec animals() :: [String.t()]
  def animals, do: @animals

  @doc """
  How many distinct usernames exist: `30 x 30 x 100`.

  Worth being able to assert rather than assume. Spec §8 caps a room at 32
  participants and 1,000 retained messages, so at most ~1,032 names can be
  unavailable at once — a little over one percent of the space, which is what makes
  the bounded retry below overwhelmingly likely to succeed on its first draw.
  """
  @spec namespace() :: pos_integer()
  def namespace, do: length(@adjectives) * length(@animals) * 100

  @doc """
  A username not present in `taken`.

  `taken` is every name that is unavailable, which since amendment A12 means the
  connected members AND the senders of every retained message — see
  `Skulkd.Room`. The retry loop is bounded: an exhausted namespace has to surface
  as a value the room can reply with, because the alternative is a room process
  that never answers the join it is in the middle of.
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
