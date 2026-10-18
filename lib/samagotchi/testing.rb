# frozen_string_literal: true

# The bundle test kit (docs/plugins.md, "Testing a bundle"): load a bundle's
# plugin and hook files through chi's own loaders, registries, Context and
# guardrail Gate, with only the edges recorded (the session's Host, the hook
# runtime, ctx.sessions, init tasks), in a sandboxed environment.
#
# EXPERIMENTAL: it may change in any release before 1.0.0; it is not part of
# "Stable for bundles".
#
#   require "samagotchi/testing"            # plain Ruby
#   require "samagotchi/testing/rspec"      # RSpec helpers
#   require "samagotchi/testing/minitest"   # Samagotchi::Testing::Case
require_relative "version"
require_relative "testing/sandbox"
require_relative "testing/recorder"
require_relative "testing/host"
require_relative "testing/sessions"
require_relative "testing/fake_http"
require_relative "testing/verdict"
require_relative "testing/recording_api"
require_relative "testing/waiting"
require_relative "testing/fake_executable"
require_relative "testing/bundle"
require_relative "testing/install"
require_relative "testing/helpers"
require_relative "testing/boundary"
