import Config

# Environment-specific overrides. All three files must exist: config_env/0 is
# resolved at compile time, so a missing dev.exs or prod.exs is a compile error
# rather than a silently skipped import.
import_config "#{config_env()}.exs"
