# frozen_string_literal: true

# samagotchi's own RuboCop cops (.rubocop.yml requires this file). They live
# outside lib/, so the gem doesn't ship them. docs/testing.md, "Waiting and
# time".
require "rubocop"

require_relative "cop/samagotchi/spec_sleep"
require_relative "cop/samagotchi/silent_wait"
