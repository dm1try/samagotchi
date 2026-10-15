# frozen_string_literal: true

require "fileutils"

# Set ENV for the block and put the previous values back after it (a nil
# value unsets the variable). Included in every example group by spec_helper.
#
#   with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run }
module SpecEnv
  def with_env(vars)
    saved = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    saved&.each { |key, value| ENV[key] = value }
  end
end

module SpecEnv
  # Point config.yml and every memory folder (MemoryPaths: memories/,
  # memories/projects/<key>, memories/.bundles) at +dir+ for the block:
  # XDG_CONFIG_HOME=dir, with the suite's fixture config.yml copied in.
  #
  #   around { |example| with_config_home(tmp) { example.run } }
  def with_config_home(dir, &)
    FileUtils.mkdir_p(File.join(dir, "samagotchi"))
    config = File.join(dir, "samagotchi", "config.yml")
    FileUtils.cp(File.join(SPEC_XDG_CONFIG_HOME, "samagotchi", "config.yml"), config) unless File.exist?(config)
    with_env("XDG_CONFIG_HOME" => dir, &)
  end
end

# The process ENV holds real API keys, so a spec never hands ENV itself to a
# matcher: a failing one inspects its actual (and a failing `with(...)` its
# arguments), printing the whole ENV. Check a key with
# `expect(ENV.fetch(key, nil)).to be_nil`; check that a value *is* ENV with
# this matcher, whose messages leave the contents out.
#
#   expect(kwargs[:env]).to be_the_process_env
RSpec::Matchers.define :be_the_process_env do
  match { |actual| actual.equal?(ENV) }
  failure_message { |actual| "expected the process ENV, got a #{actual.class} (contents not shown)" }
  failure_message_when_negated { "expected something other than the process ENV" }
  description { "be the process ENV" }
end
