# frozen_string_literal: true

require_relative "delivery"

module Samagotchi
  # Where a line typed at a terminal's prompt goes, for both terminals (the
  # REPL's TerminalUI#steer_line / #run_input_line, the attached
  # AttachedLoop#submit). It only classifies; each UI keeps what it does
  # with the answer (the REPL's mid-turn command policy and image lines, the
  # attached TUI's continue offer and question). The web's composer.js
  # routeComposerLine decides the same; spec/fixtures/composer_routes.json
  # holds the cases both answer (docs/testing.md).
  #
  # In order:
  #   1. /cut TEXT, /queue TEXT (.steer_choice), before every command check:
  #      the bare word is :usage. While a turn runs TEXT is a :deliver with
  #      its delivery (Delivery::CUT, Delivery::QUEUE), or :unavailable for
  #      a /queue the UI can't queue yet. With none running TEXT is routed
  #      on as a line (step 2), its own /cut not read again.
  #   2. A line: :empty; a terminal's own word (:local, the registry's
  #      lookup_local id: :exit, :archive, :detach, :stats, :recap…); a
  #      session command (:command); a typo of one (:typo, the hint in
  #      +reply+); else :prompt. A line with images (+images+) is a message:
  #      no command or typo check.
  module ComposerRoute
    CUT_COMMAND = "/cut"
    QUEUE_COMMAND = "/queue"
    # The word, then any whitespace and the text (as the registry's
    # entries match them, so a line Tab or /help knows is never a prompt).
    STEER_CHOICE = /\A(#{CUT_COMMAND}|#{QUEUE_COMMAND})(?:\s+(.*))?\z/m

    KINDS = %i[empty usage unavailable deliver local command typo prompt].freeze

    # @!attribute kind [Symbol] one of KINDS
    # @!attribute text [String, nil] the line stripped: a /cut's or
    #   /queue's own text, not the word
    # @!attribute delivery [String, nil] a :deliver's Delivery value
    # @!attribute reply [String, nil] a :typo's hint
    # @!attribute local [Symbol, nil] a :local's registry id
    # @!attribute choice [Symbol, nil] :cut or :queue when the line was
    #   typed with that word (an idle one's text routed on keeps it)
    Route = Data.define(:kind, :text, :delivery, :reply, :local, :choice) do
      def initialize(kind:, text: nil, delivery: nil, reply: nil, local: nil, choice: nil)
        super
      end
    end

    # @param line [String, nil] as typed
    # @param running [Boolean] a turn runs
    # @param registry [Commands::Registry] the session's commands
    # @param images [Integer] the attachments not in the text (the web's
    #   chips); a terminal's @path images are its own to handle (0)
    # @param queue [Boolean] the UI takes /queue TEXT while a turn runs (the
    #   REPL's after-turn list); else it is :unavailable
    # @return [Route]
    def self.call(line, running:, registry:, images: 0, queue: false)
      text = line.to_s.strip
      choice, message = steer_choice(text)
      return line_route(text, registry: registry, images: images) unless choice
      return Route.new(kind: :usage, choice: choice) if message.empty?
      return line_route(message, registry: registry, images: images).with(choice: choice) unless running
      return Route.new(kind: :unavailable, text: message, choice: choice) if choice == :queue && !queue

      Route.new(kind: :deliver, text: message, delivery: choice == :cut ? Delivery::CUT : Delivery::QUEUE, choice: choice)
    end

    # The choice a line carries, as [:cut, "TEXT"] or [:queue, "TEXT"]; nil
    # for any other line. The text is "" when the line named the choice
    # without one.
    # @param line [String, nil]
    # @return [Array(Symbol, String), nil]
    def self.steer_choice(line)
      match = STEER_CHOICE.match(line.to_s.strip) or return nil

      [match[1] == CUT_COMMAND ? :cut : :queue, match[2].to_s.strip]
    end

    def self.line_route(text, registry:, images:)
      return Route.new(kind: :empty, text: text) if text.empty?

      if images.zero?
        local = registry.lookup_local(text)&.id
        return Route.new(kind: :local, text: text, local: local) if local
        return Route.new(kind: :command, text: text) if registry.command?(text)

        hint = registry.unknown_command_hint(text)
        return Route.new(kind: :typo, text: text, reply: hint) if hint
      end
      Route.new(kind: :prompt, text: text)
    end
    private_class_method :line_route
  end
end
