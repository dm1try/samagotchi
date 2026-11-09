# frozen_string_literal: true

module Samagotchi
  # A versioned JSON state-file schema. Missing members must be required or
  # declare the format version and default that introduced them.
  class StateFormat
    REQUIRED = Object.new.freeze

    Member = Data.define(:name, :introduced_in, :default, :persisted) do
      def required? = introduced_in.nil?
      def defaulted? = !required?
      def persisted? = persisted
    end

    Record = Data.define(:attributes, :extra, :raw, :missing) do
      def readable? = missing.empty?

      def to_h
        return raw unless readable?

        extra.transform_keys(&:to_s).merge(attributes.transform_keys(&:to_s))
      end
    end

    Document = Data.define(:version, :extra, :entries)

    class InvalidDocument < StandardError; end

    def self.required(name)
      Member.new(name: name.to_sym, introduced_in: nil, default: REQUIRED, persisted: true)
    end

    def self.added(name, in_version:, default:)
      Member.new(name: name.to_sym, introduced_in: in_version, default: default, persisted: true)
    end

    def self.extra(name, in_version:)
      Member.new(name: name.to_sym, introduced_in: in_version, default: ->(_attributes) { {} }, persisted: false)
    end

    attr_reader :members

    def initialize(version:, members:)
      @version = version
      @members = members.freeze
      @extra_member = members.find { |member| !member.persisted? }
      raise ArgumentError, "a state format can declare only one extra member" if members.count { |member| !member.persisted? } > 1
      raise ArgumentError, "duplicate state format members" unless members.map(&:name).uniq == members.map(&:name)

      members.each do |member|
        required = member.required? && member.default.equal?(REQUIRED)
        defaulted = member.defaulted? && member.introduced_in.is_a?(Integer) &&
                    member.introduced_in.positive? && member.introduced_in <= version &&
                    !member.default.equal?(REQUIRED)
        next if required || defaulted

        raise ArgumentError, "#{member.name} must be required or have an introduction version and default"
      end
    end

    def read(data, collection:)
      raise InvalidDocument, "the state file must contain a JSON object" unless data.is_a?(Hash)

      collection = collection.to_s
      entries = Array(data[collection]).map { |raw| read_record(raw) }
      known = %w[version updated_at] + [collection]
      stored_version = data["version"]
      stored_version = 0 unless stored_version.is_a?(Integer) && stored_version >= 0

      Document.new(version: [@version, stored_version].max,
                   extra: data.reject { |key, _value| known.include?(key.to_s) },
                   entries: entries)
    end

    def write(document, collection:, updated_at:)
      document.extra.transform_keys(&:to_s).merge(
        "version" => [document.version, @version].max,
        "updated_at" => updated_at,
        collection.to_s => document.entries.map(&:to_h)
      )
    end

    private

    def read_record(raw)
      unless raw.is_a?(Hash)
        missing = members.select(&:required?).map(&:name)
        return Record.new(attributes: {}, extra: {}, raw: raw, missing: missing)
      end

      attributes = {}
      missing = []
      members.each do |member|
        next unless member.persisted?

        key = member.name.to_s
        if raw.key?(key)
          attributes[member.name] = raw[key]
        elsif member.required?
          missing << member.name
        else
          attributes[member.name] = default_value(member.default, attributes)
        end
      end

      known = members.select(&:persisted?).map { |member| member.name.to_s }
      extra = raw.reject { |key, _value| known.include?(key.to_s) }
      extra = default_value(@extra_member.default, attributes).merge(extra) if @extra_member
      Record.new(attributes: attributes, extra: extra, raw: raw, missing: missing)
    end

    def default_value(default, attributes)
      value = default.respond_to?(:call) ? default.call(attributes) : default
      value = value.dup if value.is_a?(Hash) || value.is_a?(Array)
      value
    end
  end
end
