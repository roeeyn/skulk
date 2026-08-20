import Config

if config_env() == :test do
  # argon2id is deliberately expensive — that is the point of it. At default cost the
  # room test suite would spend most of its wall clock hashing passwords it does not
  # care about. These are the minimum legal parameters, and they apply to :test ONLY;
  # production keeps argon2_elixir's defaults.
  config :argon2_elixir, t_cost: 1, m_cost: 8
end
