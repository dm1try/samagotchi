# frozen_string_literal: true

module Samagotchi
  # One key of a session file (a Session::FIELDS row): +key+ the file's
  # key, +attr+ Session's attribute and keyword (nil for a key only the
  # file has: the settings pair, written from Session's +from+), +default+
  # the value of a file without the key (REQUIRED for one it must have),
  # +fresh+ a new Session's when it isn't given (it differs only for
  # metadata_version and messages), +optional+ a key written only when set,
  # +cast+ what a value is read as (Session.new, .from_h and the writers),
  # +write+ what the file gets from the attribute (the value as is without
  # one). +unread+ and +keep+ are the Unread rule's (.level): what of a
  # value the field couldn't read the session keeps, and how the file gets
  # it back. A leaf: the types a row names are named in session.rb, in a
  # block its lambdas call (`type.call`, not `yield`: never while the
  # constructor runs, so Performance/RedundantBlockCall is off for them).
  SessionField = Data.define(:key, :attr, :from, :default, :fresh, :optional, :cast, :write, :unread, :keep) do
    # A field read as given, or through +cast+; +unread+ and +keep+ give
    # it the Unread rule (see .level).
    def self.plain(key, default, cast: nil, write: nil, fresh: default, optional: false, unread: nil, keep: nil)
      new(key: key, attr: key.to_sym, from: nil, default: default, fresh: fresh, optional: optional, cast: cast,
          write: write, unread: unread, keep: keep)
    end

    # rubocop:disable Performance/RedundantBlockCall
    # A value object's field (nil for none): a value that is already one
    # is taken as it is, nil is nil (the type isn't loaded for it: an
    # autoloaded one stays unloaded), anything else is read with the type's
    # +reader+ (from_file, of); the file gets its #to_file, through
    # .scrub_utf8 with +scrub+. +type+ is a block, so the row names its type
    # without loading it.
    def self.value(key, reader, optional: false, scrub: false, &type)
      cast = lambda do |value|
        next nil if value.nil?

        klass = type.call
        value.is_a?(klass) ? value : klass.public_send(reader, value)
      end
      write = scrub ? ->(value) { value && scrub_utf8(value.to_file) } : ->(value) { value&.to_file }
      new(key: key, attr: key.to_sym, from: nil, default: nil, fresh: nil, optional: optional, cast: cast,
          write: write, unread: nil, keep: nil)
    end

    # A list of value objects ([] for none): read with the type's .list, each
    # written with its #to_file.
    def self.list(key, &type)
      new(key: key, attr: key.to_sym, from: nil, default: [], fresh: [], optional: false,
          cast: ->(value) { type.call.list(value) }, write: ->(values) { values.map(&:to_file) }, unread: nil,
          keep: nil)
    end

    # A session's own level (nil for none), with the Unread rule: a value
    # that isn't one reads as nil, and the session keeps it as written (a
    # newer chi's level, a hand edit) and saves it back so, until it sets
    # its own. A level is the type's .session_level of the value; a String
    # that doesn't read as one, other than the +unset+ word (any case and
    # spaces), is the one kept. With +merge_unread+ the field is a value
    # object of several parts (LLMContextOverride: .from_file, .unread):
    # the parts it couldn't read are kept, and the file gets them under the
    # parts it has (nil when there is none).
    def self.level(key, unset: nil, merge_unread: false, &type)
      if merge_unread
        cast = ->(value) { type.call.from_file(value) }
        unread = ->(value) { type.call.unread(value) }
        write = ->(value) { value&.to_file }
        keep = lambda do |written, kept|
          saved = kept.merge(written || {})
          saved.empty? ? nil : saved
        end
      else
        cast = ->(value) { type.call.session_level(value) }
        unread = lambda do |value|
          value if value.is_a?(String) && type.call.session_level(value).nil? && !value.strip.casecmp?(unset)
        end
        write = ->(value) { value&.to_s }
        keep = ->(written, kept) { written || kept }
      end
      new(key: key, attr: key.to_sym, from: nil, default: nil, fresh: nil, optional: false, cast: cast, write: write,
          unread: unread, keep: keep)
    end
    # rubocop:enable Performance/RedundantBlockCall

    # A key only the file has: +write+ takes Session's +from+ attribute.
    def self.file_only(key, default, from:, write:)
      new(key: key, attr: nil, from: from, default: default, fresh: nil, optional: false, cast: nil, write: write,
          unread: nil, keep: nil)
    end

    def required? = default.equal?(SessionField::REQUIRED)

    def fresh_required? = fresh.equal?(SessionField::REQUIRED)

    # A new Session's value when it isn't given: a fresh copy of a list or
    # a Hash, never one shared with another session.
    def fresh_value = fresh.is_a?(Array) || fresh.is_a?(Hash) ? fresh.dup : fresh

    # The instance variable #to_h reads (never the reader: project_root's
    # and verdicts' have logic of their own).
    def ivar = :"@#{attr || from}"

    # +value+ as the attribute holds it.
    def cast_value(value) = cast ? cast.call(value) : value

    # The attribute's +value+ as the file holds it, with what the session
    # kept of a value it couldn't read (+kept+, .level's).
    def dump(value, kept = nil)
      written = write ? write.call(value) : value
      keep ? keep.call(written, kept) : written
    end

    # The last guard before JSON.generate, which raises on bytes that
    # aren't UTF-8: a save that raised would lose the whole conversation.
    # ToolRunner already scrubs tool output; this covers any other source.
    def self.scrub_utf8(obj)
      case obj
      when String
        str = obj.encoding == Encoding::UTF_8 ? obj : obj.dup.force_encoding(Encoding::UTF_8)
        str.valid_encoding? ? str : str.scrub("?")
      when Array then obj.map { |element| scrub_utf8(element) }
      when Hash then obj.to_h { |key, value| [key, scrub_utf8(value)] }
      else obj
      end
    end

    # A Hash with String keys (one level).
    def self.stringify_keys(hash)
      hash.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
    end
  end

  # A field a session file must have (KeyError without it, ArgumentError
  # from Session.new).
  SessionField::REQUIRED = Object.new.freeze
end
