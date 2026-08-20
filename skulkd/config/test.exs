import Config

# argon2id is deliberately expensive — that is the point of it. At default cost the
# room suite would spend most of its wall clock hashing passwords it does not care
# about. These are the minimum legal parameters, and because they live in test.exs
# they cannot leak into dev or prod, which keep argon2_elixir's defaults.
config :argon2_elixir, t_cost: 1, m_cost: 8
