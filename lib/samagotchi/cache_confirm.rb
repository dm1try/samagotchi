# frozen_string_literal: true

module Samagotchi
  # The confirm step before a session setting change that restarts the
  # prompt cache (/thinking, /reasoning-history): such a change, sent
  # without --yes from a person at a web tab or a chi TUI, changes nothing
  # and replies with what it costs and the line that applies it. Two steps,
  # no stored state: the reply carries a Confirm (SessionCommands::Result,
  # the worker's command_ran), the TUI prefills its line, the web draws an
  # Apply button that sends it.
  module CacheConfirm
    YES_FLAGS = %w[--yes -y].freeze
    # The costs worth asking about (Thinking.cache_cost,
    # ReasoningHistory.cache_cost); :tail and nil are not.
    COSTLY = %i[full provider history].freeze

    # The line that applies a change, and the question the reply ends with.
    Confirm = Data.define(:line, :text) do
      # The plain form the worker's command_ran carries.
      # @return [Hash] symbol keys
      def to_h = { line: line, text: text }
    end

    module_function

    # A command's argument words with --yes / -y (anywhere) taken out.
    # @param args [String] what follows the command name
    # @return [Array(String, Boolean)] the rest, stripped and downcased, and
    #   whether --yes was there
    def split(args)
      words = args.to_s.strip.downcase.split
      yes = words.any? { |word| YES_FLAGS.include?(word) }
      [(words - YES_FLAGS).join(" "), yes]
    end

    # Whether a change must ask first: the effective level changes, the
    # cost is one of COSTLY, and the session has a model reply (a cache to
    # restart at all).
    def needed?(cost:, history:, changed:)
      changed && history && COSTLY.include?(cost)
    end

    # The Confirm for +name+ set to +word+: the line with --yes, and the
    # question naming it.
    # @return [Confirm]
    def confirm(name, word)
      line = "#{name} #{word} --yes"
      Confirm.new(line: line, text: "Nothing changed yet: send `#{line}` to apply.")
    end
  end
end
