import Config

# Nothing overridden — production keeps every library default, argon2_elixir's cost
# parameters included, and every spec §8 bound at the default in `Skulkd.Limits`. That
# module lists the keys to set here to change one. The file exists because config.exs
# imports one per environment; see the note there.
