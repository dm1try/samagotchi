# frozen_string_literal: true

module Samagotchi
  # The confirm step before a command that restarts the prompt cache: sent
  # without --yes by a person at a web tab or a chi TUI, it changes nothing
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
    # @param downcase [Boolean] false keeps the words' case (/toolkit: a
    #   plugin's or MCP server's tool names can be mixed case)
    # @return [Array(String, Boolean)] the rest, stripped (and downcased),
    #   and whether --yes was there
    def split(args, downcase: true)
      text = args.to_s.strip
      words = (downcase ? text.downcase : text).split
      flags, rest = words.partition { |word| YES_FLAGS.include?(word.downcase) }
      [rest.join(" "), !flags.empty?]
    end

    # Whether a change must ask first: the effective level changes, the
    # cost is one of COSTLY, and the session has a model reply (a cache to
    # restart at all).
    def needed?(cost:, history:, changed:)
      changed && history && COSTLY.include?(cost)
    end

    # Whether a cache-changing command should ask, and its reply line.
    # Kept independent of any UI so commands and plugins can share it.
    # @param line [String] the full command line without --yes
    # @param cost [Symbol, nil] the change's cache cost
    # @param changed [Boolean] whether the effective setting changes
    # @param engine [Engine] supplies history, used tokens and model host
    # @return [Confirm, nil]
    def ask(line:, cost:, changed:, engine:)
      return nil unless needed?(cost: cost, history: engine.history?, changed: changed)

      apply_line = "#{line.to_s.strip} --yes"
      notes = []
      tokens = engine.cache_restart_tokens
      if tokens
        size = tokens >= 1000 ? "#{format("%.1f", tokens / 1000.0).delete_suffix(".0")}k" : tokens.to_s
        notes << case cost
                 when :full, :provider
                   "The next request reads the whole conversation again (about #{size} tokens)."
                 when :history
                   "The next request reads again from the first changed reply (up to about #{size} tokens)."
                 end
      end
      if %i[full provider].include?(cost) && engine.cache_restart_anthropic?
        notes << "On an `api: anthropic` host, preserved thinking in replies is dropped from then on."
      end
      notes << "Nothing changed yet: send `#{apply_line}` to apply."
      Confirm.new(line: apply_line, text: notes.compact.join("\n"))
    end
  end
end
