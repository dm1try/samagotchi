# frozen_string_literal: true

require_relative "guardrails/parent_policy"

module Samagotchi
  # /parent-answers, the session's own guardrails.parent_answers
  # (Session#parent_answers): with no argument, the level that applies, the
  # session's own and config.yml's; `/parent-answers LEVEL` (hard, standard,
  # soft) or `default` (none of its own) sets it, saved at once, for the next
  # answer a parent gives. It may only tighten config.yml's
  # (Guardrails::ParentPolicy.effective). Tightening goes from anyone;
  # loosening (toward soft, or default) only from a user at a UI: the REPL,
  # an attached TUI, the web (+user_ui+). A parent agent's line (chi send,
  # a piped or marked attach, a delegate's follow-up) is refused.
  class ParentAnswersCommand
    NAME = "/parent-answers"
    USAGE = "usage: #{NAME} [hard|standard|soft|default]".freeze
    REFUSED = "loosening parent_answers is the user's: #{NAME} in chi --attach, the REPL or the web " \
              "(not chi send or a parent agent)".freeze

    # What +args+ (the text after the name) asks for.
    # @return [Array] [:show], [:set, level or nil (default)] or [:usage]
    def self.parse(args)
      words = args.to_s.split
      return [:show] if words.empty?
      return [:usage] if words.size > 1

      case (level = Guardrails::ParentPolicy.parse_level(words.first))
      when :unset then [:set, nil]
      when :invalid then [:usage]
      else [:set, level]
      end
    end

    # Whether the command line +line+ loosens a session whose own value is
    # +current+ (chi send's early refusal, before it sends the line).
    def self.loosens?(line, current)
      kind, value = parse(line.to_s.strip.delete_prefix(NAME))
      kind == :set && Guardrails::ParentPolicy.looser?(current, value)
    end

    # @param engine [Engine] #session
    # @param save [#call] saves the session after a change
    def initialize(engine:, save:)
      @engine = engine
      @save = save
    end

    # @param args [String] what follows /parent-answers
    # @param user_ui [Boolean] a user at a UI typed it: it may loosen
    # @return [Array(String, Boolean, Symbol)] the reply, whether the
    #   session's value changed, and :ok or :error
    def run(args, user_ui:)
      session = @engine.session or return ["no session yet", false, :error]
      kind, value = self.class.parse(args)
      return [USAGE, false, :error] if kind == :usage
      return [listing(session), false, :ok] if kind == :show
      return ["#{listing(session)}\n(no change)", false, :ok] if value == session.parent_answers
      return [REFUSED, false, :error] if Guardrails::ParentPolicy.looser?(session.parent_answers, value) && !user_ui

      session.parent_answers = value
      @save.call(session)
      capped = Guardrails::ParentPolicy.capped_note(value)
      [[listing(session), ("(#{capped})" if capped)].compact.join("\n"), true, :ok]
    end

    private

    # "parent answers: standard (this session: standard; config.yml
    # guardrails.parent_answers: soft)"
    def listing(session)
      config = Guardrails::ParentPolicy.current
      effective = Guardrails::ParentPolicy.for_session(session)
      own = session.parent_answers || "none"
      # A hand-edited value that isn't a level: fail-closed, said here.
      own = "#{own} (unreadable value, read as hard)" if Guardrails::ParentPolicy.unknown_level?(session.parent_answers)
      "parent answers: #{effective.name} (this session: #{own}; config.yml #{config.label})"
    end
  end
end
