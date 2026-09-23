# frozen_string_literal: true

module Samagotchi
  # How `bin/chi` runs a session: attached to a worker (as `--attach` and
  # `--shared` do) or in the plain in-process REPL. With `session.shared` on,
  # plain `chi` runs attached unless it asks for something attached mode
  # can't do yet.
  module LaunchMode
    # Options an attached TUI can't honor: the worker takes its model from
    # the session, takes no memories, and its Engine gets neither flag.
    REPL_ONLY = { model: "--model", memories: "--memory", verbose: "--verbose", no_interrupt: "--no-interrupt" }.freeze

    module_function

    # @param options [Hash] bin/chi's parsed options
    # @param shared_config [Boolean] the session.shared config value
    # @return [Array(Symbol, String)] :attached or :repl, and a note for the
    #   user when the config asked for attached mode but didn't get it
    def resolve(options, shared_config:)
      return [:attached, nil] if options[:attach] || options[:shared]
      # --no-shared, or nobody asked for attached mode.
      return [:repl, nil] if options[:shared] == false || !shared_config
      # A one-shot with no REPL: nothing to attach.
      return [:repl, nil] if options[:non_interactive]

      flag = REPL_ONLY.find { |key, _flag| options[key] }&.last
      return [:repl, "(session.shared: #{flag} runs in a plain REPL)"] if flag

      [:attached, nil]
    end
  end
end
