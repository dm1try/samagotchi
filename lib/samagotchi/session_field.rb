# frozen_string_literal: true

module Samagotchi
  # One key of a session file (a Session::FIELDS row): +key+ the file's
  # key, +attr+ Session's attribute and keyword (nil for a key only the
  # file has: the settings pair, written from Session's +from+), +default+
  # the value of a file without the key (REQUIRED for one it must have),
  # +fresh+ a new Session's when it isn't given (it differs only for
  # metadata_version and messages), +optional+ a key written only when set,
  # +cast+ what a value is read as (Session.new, .from_h and a casting
  # writer), +write+ what the file gets from the attribute (the value as is
  # without one). A leaf: the types a row names are named in session.rb.
  SessionField = Data.define(:key, :attr, :from, :default, :fresh, :optional, :cast, :write, :via_writer) do
    # A field read as given, or through +cast+.
    def self.plain(key, default, cast: nil, write: nil, fresh: default, optional: false)
      new(key: key, attr: key.to_sym, from: nil, default: default, fresh: fresh, optional: optional, cast: cast,
          write: write, via_writer: false)
    end

    # A value object's field (nil for none): a value that is already one
    # is taken as it is, nil is nil (the type isn't loaded for it: an
    # autoloaded one stays unloaded), anything else is read with the type's
    # +reader+ (from_file, of); the file gets its #to_file, through
    # .scrub_utf8 with +scrub+. +type+ is a block, so the row names its type
    # without loading it.
    def self.value(key, reader, optional: false, scrub: false, &type)
      cast = lambda do |value|
        next nil if value.nil?

        klass = yield
        value.is_a?(klass) ? value : klass.public_send(reader, value)
      end
      write = scrub ? ->(value) { value && scrub_utf8(value.to_file) } : ->(value) { value&.to_file }
      new(key: key, attr: key.to_sym, from: nil, default: nil, fresh: nil, optional: optional, cast: cast,
          write: write, via_writer: false)
    end

    # A list of value objects ([] for none): read with the type's .list, each
    # written with its #to_file.
    def self.list(key, &type)
      new(key: key, attr: key.to_sym, from: nil, default: [], fresh: [], optional: false,
          cast: ->(value) { yield.list(value) }, write: ->(values) { values.map(&:to_file) }, via_writer: false)
    end

    # A field Session.new sets through Session's public writer (#<attr>=),
    # written by #to_h's own arm.
    def self.typed(key, default, optional: false)
      new(key: key, attr: key.to_sym, from: nil, default: default, fresh: default, optional: optional, cast: nil,
          write: nil, via_writer: true)
    end

    # A key only the file has: +write+ takes Session's +from+ attribute.
    def self.file_only(key, default, from:, write:)
      new(key: key, attr: nil, from: from, default: default, fresh: nil, optional: false, cast: nil, write: write,
          via_writer: false)
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
    def load(value) = cast ? cast.call(value) : value

    # The attribute's +value+ as the file holds it.
    def dump(value) = write ? write.call(value) : value

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
