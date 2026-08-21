import Config

# Read at BOOT, not at compile time — which is the entire point of this file, and
# why a released relay can be configured by the environment of the container it
# runs in rather than by the machine that built the image.
#
# Everything interesting lives in Skulkd.Config, a pure function from an
# environment map to a keyword list, because logic in a config file is logic no
# test can reach. This file is its only caller.
#
# :prod only. This file is evaluated in every environment, and a strict parser
# reading a developer's or a CI runner's environment is a suite that fails for
# reasons nobody can see. Tests configure Skulkd.Config directly.
if config_env() == :prod do
  config :skulkd, Skulkd.Config.from_env(System.get_env())
end
