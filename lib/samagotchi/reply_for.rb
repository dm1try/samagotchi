# frozen_string_literal: true

require_relative "config"
require_relative "steer"

module Samagotchi
  # What the surface a message was sent from can show, declared by a thin
  # client on POST …/ask as "reply_for" (docs/thin-clients.md): a name
  # (config.yml's surfaces:, `voice` by default) or the values themselves.
  # chi knows values, never surfaces:
  # - formatting: "markdown" or "plain";
  # - room: "long", "short" (at most SHORT_WORDS words) or "one_line" (at
  #   most ONE_LINE_CHARS characters);
  # - choices: "many" or how many options a question may offer (0..9);
  # - detail: true, or false (no commands, code or diffs; no approvals,
  #   spending questions or user-only options either: ReplyShape).
  # A missing value is the full one, and a value that is full everywhere is
  # no ReplyFor at all (nil): full is the absence of a value, never a
  # stored "full", so a full ask sends and saves what no ask does.
  #
  # One member of a turn's TurnAnchors: it rides from chi web to the Engine
  # as verify and revises do, and is saved (#to_file, the values with
  # string keys) on the turn's opening user message beside the baked
  # wording the model reads (#line), so a later release that rewords a
  # value never changes an old turn's bytes (.opener_fields).
  class ReplyFor < Data.define(:formatting, :room, :choices, :detail)
    # A refused name, key or value (POST …/ask's 400 invalid_ask): the
    # message says which and what it may be.
    class Invalid < ArgumentError; end

    # The worker's Bridge feature (Bridge::FEATURES): it saves the field and
    # bakes its line. chi web sends the field to no worker without it.
    FEATURE = "reply_for"
    # A worker without FEATURE (SessionManager::Delivery). The session
    # restarts on the chi home that made it, so a restart alone may not be
    # enough: the words don't promise it.
    UNAVAILABLE = {
      "error" => "reply_for_unavailable",
      "detail" => "this session's worker is older than reply_for, so the message was not sent: " \
                  "update chi if needed, then restart the session (chi sessions restart ID)"
    }.freeze

    FORMATTING = %w[markdown plain].freeze
    ROOM = %w[long short one_line].freeze
    CHOICES_MAX = 9
    # The full value of each member.
    FULL = { "formatting" => "markdown", "room" => "long", "choices" => "many", "detail" => true }.freeze
    KEYS = FULL.keys.freeze
    # The names every chi knows; config.yml's surfaces: adds or replaces.
    DEFAULT_NAMES = {
      "voice" => { "formatting" => "plain", "room" => "short", "choices" => 3, "detail" => false }.freeze
    }.freeze

    # The counted limits the room's wording says.
    SHORT_WORDS = 60
    ONE_LINE_CHARS = 80

    # Where both of chi's lines open (#line, RETURN_LINE): one lead, so a
    # copy of it inside someone else's text is quoted on the wire
    # (Steer::FORGED_OPENINGS).
    LEAD = Steer::REPLY_LEAD
    # The line the first undeclared opener after a declared one gets
    # (.opener_fields): the style set for a small surface sticks to the next
    # reply otherwise.
    RETURN_LINE = "[#{LEAD}: the user is back on a full screen, where markdown, lists, code and long replies " \
                  "show again. Reply as usual from here.]".freeze

    # The opening user message's saved keys (ChatLoop#plain keeps both).
    MESSAGE_KEY = :reply_for
    LINE_KEY = Steer::REPLY_LINE_KEY

    class << self
      # A POST …/ask body's "reply_for": a name (+names+) or the values.
      # @param value [String, Hash, nil]
      # @param names [Hash{String => Hash}] the known names' values (.names)
      # @return [ReplyFor, nil] nil: none given, or full everywhere
      # @raise [Invalid]
      def parse(value, names: self.names)
        return nil if value.nil?

        case value
        when String
          values = names.fetch(value) { raise Invalid, "reply_for: unknown name #{value.inspect} (known: #{names.keys.sort.join(", ")})" }
          checked(values, where: "reply_for #{value.inspect}")
        when Hash then checked(value, where: "reply_for")
        else raise Invalid, "reply_for is a name or an object of #{KEYS.join(", ")}"
        end
      end

      # A carried or saved value (the Bridge body, the input file, a saved
      # message): the values only, string or symbol keys; anything
      # malformed is nil, as the other anchors read theirs.
      # @return [ReplyFor, nil]
      def from(value)
        return value if value.is_a?(self)
        return nil unless value.is_a?(Hash)

        checked(value, where: "reply_for")
      rescue Invalid
        nil
      end

      # The names an ask may give: DEFAULT_NAMES, then config.yml's
      # surfaces: (a name there replaces a default). An entry is checked
      # when an ask names it (.parse), so a bad one refuses only that name.
      # @return [Hash{String => Hash}]
      def names(env: ENV)
        configured = ConfigFile.read_yaml(env: env)&.dig("surfaces")
        configured = {} unless configured.is_a?(Hash)
        DEFAULT_NAMES.merge(configured.to_h { |name, values| [name.to_s, values] })
      end

      # The fields a turn's opening user message is saved with
      # (Engine#turn_messages, and the worker's checkpoint copy of it):
      # +declared+'s values and line; else, when the latest opener in
      # +history+ declared one (.latest_opener), the return line alone; else
      # none, so a session that never declares keeps its bytes. The return
      # line ends the run: the opener carrying it declares nothing. Read
      # from the history alone (no session state), so a one-shot --resume,
      # a schedule's or an agent's opener get it too.
      # @param history [Array<Hash>] the session's messages before this one
      # @param declared [ReplyFor, Hash, nil]
      # @return [Hash{Symbol => Object}]
      def opener_fields(history, declared)
        declared = from(declared)
        return { MESSAGE_KEY => declared.to_file, LINE_KEY => declared.line } if declared

        last = latest_opener(history)
        last && from(last[MESSAGE_KEY] || last[MESSAGE_KEY.to_s]) ? { LINE_KEY => RETURN_LINE } : {}
      end

      # The latest message in +history+ that opened a turn from a sender
      # (Engine#turn_messages' user message): a user message with no kind
      # that is not a !shell line. A wake's note or report, a steer and
      # merged input have a kind (or are a system message), so they never
      # hide the turn before them.
      # @return [Hash, nil]
      def latest_opener(history)
        Array(history).reverse_each.find do |message|
          next false unless message.is_a?(Hash) && (message[:role] || message["role"]).to_s == "user"
          next false unless (message[:kind] || message["kind"]).to_s.empty?

          !Steer.shell_line?(message)
        end
      end

      private

      def checked(value, where:)
        unless value.is_a?(Hash)
          raise Invalid, "#{where} is a mapping of #{KEYS.join(", ")}"
        end

        fields = value.to_h { |key, entry| [key.to_s, entry] }
        unknown = fields.keys - KEYS
        raise Invalid, "#{where}: unknown key #{unknown.first.inspect} (known: #{KEYS.join(", ")})" unless unknown.empty?

        values = FULL.merge(fields)
        raise Invalid, "#{where}: formatting is #{FORMATTING.join(" or ")}" unless FORMATTING.include?(values["formatting"])
        raise Invalid, "#{where}: room is #{ROOM.join(", ")}" unless ROOM.include?(values["room"])
        unless values["choices"] == "many" || (values["choices"].is_a?(Integer) && values["choices"].between?(0, CHOICES_MAX))
          raise Invalid, "#{where}: choices is \"many\" or 0..#{CHOICES_MAX}"
        end
        raise Invalid, "#{where}: detail is true or false" unless [true, false].include?(values["detail"])
        return nil if values == FULL

        new(formatting: values["formatting"], room: values["room"], choices: values["choices"], detail: values["detail"])
      end
    end

    # The values, string keys (the saved form, the body's and the input
    # file's).
    def to_file = { "formatting" => formatting, "room" => room, "choices" => choices, "detail" => detail }

    # A :prompt_restored event's field.
    def to_h = to_file

    def plain? = formatting == "plain"

    def detail? = detail

    # One phrase per restricted value, in a fixed order; a full value says
    # nothing.
    FORMATTING_WORDS = {
      "plain" => "shows plain text only, so write plain spoken sentences, not lists: no markdown (no headings, bullets, " \
                 "numbered lists, tables, bold or code), no emoji, no links"
    }.freeze
    ROOM_WORDS = {
      "short" => "has room for a short reply of at most #{SHORT_WORDS} words",
      "one_line" => "has room for one line of at most #{ONE_LINE_CHARS} characters: one short sentence, the answer only"
    }.freeze
    DETAIL_WORDS = { false => "can't show commands, code or diffs: describe them in words" }.freeze

    def choice_words
      case choices
      when "many" then nil
      when 0, 1 then "can't offer a list of choices: if you must ask, ask one yes-or-no question"
      else "can offer at most #{choices} choices: if you must ask, offer no more than #{choices} options"
      end
    end

    # The line the model reads above the user's text (Steer.wire_text),
    # baked on the message when it is made.
    def line
      clauses = [FORMATTING_WORDS[formatting], ROOM_WORDS[room], choice_words, DETAIL_WORDS[detail]].compact
      "[#{LEAD}: the user sent it from a surface that #{clauses.join("; ")}. Write this one reply to fit it.]"
    end
  end
end
