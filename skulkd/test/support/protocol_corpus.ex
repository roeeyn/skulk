defmodule Skulkd.ProtocolCorpus do
  @moduledoc """
  Loads `docs/protocol/corpus/` at compile time so each vector becomes its own
  ExUnit test. Format: `docs/protocol/corpus/README.md`.
  """

  @dir Path.expand("../../../docs/protocol/corpus", __DIR__)

  def dir, do: @dir

  def registry, do: read_json!(Path.join(@dir, "registry.json"))

  def valid, do: load("valid")
  def invalid, do: load("invalid")

  def files do
    [Path.join(@dir, "registry.json") | Path.wildcard(Path.join(@dir, "{valid,invalid}/*.json"))]
  end

  defp load(kind) do
    @dir
    |> Path.join("#{kind}/*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path -> Map.put(read_json!(path), "path", path) end)
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  @doc """
  Reconstructs the exact frame bytes a vector describes. Exactly one of
  `wire.json`, `wire.raw`, `wire.base64` is set.

  `wire.json` is re-serialized compactly, so its byte length is not stable across
  languages; vectors whose length is under test use `wire.raw`.
  """
  def frame_bytes(%{"wire" => wire}) do
    case wire do
      %{"json" => value} -> {:ok, Jason.encode!(value)}
      %{"raw" => raw} when is_binary(raw) -> {:ok, raw}
      %{"base64" => b64} when is_binary(b64) -> Base.decode64(b64)
      _ -> :error
    end
  end

  def receiver(%{"receiver" => "relay"}), do: :relay
  def receiver(%{"receiver" => _}), do: :client

  def kind(%{"wire" => %{"kind" => "binary"}}), do: :binary
  def kind(%{"wire" => _}), do: :text
end
