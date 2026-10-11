# frozen_string_literal: true

require "uri"

module Samagotchi
  # One thing a click on a ref can do besides the kind's own (the web keeps
  # those per kind, refs.js REF_ACTIONS): open +url+ in a new tab, shown as
  # +label+ in the ref's menu. A plugin names it ("PR diff", "Open in Jira").
  # The URL is http(s) only, checked here and again in the page
  # (refs.js httpUrl): the page opens it as is, so a javascript:, data: or
  # editor URL never gets there.
  RefAction = Data.define(:id, :label, :url) do
    # @raise [ArgumentError] an empty id or label, or a URL that isn't an
    #   http(s) one with a host, at most MAX_URL characters
    def initialize(id:, label:, url:)
      id = id.to_s.strip
      label = label.to_s.strip
      url = url.to_s.strip
      raise ArgumentError, "a ref action needs an id" if id.empty?
      raise ArgumentError, "a ref action needs a label" if label.empty?
      raise ArgumentError, "a ref action's url must be http(s) with a host, at most #{RefAction::MAX_URL} characters" unless RefAction.http_url?(url)

      super
    end
  end

  class RefAction
    MAX_URL = 2_000

    # @return [Boolean] +url+ is an http or https URL with a host
    def self.http_url?(url)
      return false if url.length > MAX_URL

      uri = URI.parse(url)
      uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
    rescue URI::InvalidURIError
      false
    end

    # @param value [RefAction, Hash] a plugin's {id:, label:, url:} (String
    #   or Symbol keys)
    # @raise [ArgumentError] anything else, or an invalid action
    def self.from(value)
      return value if value.is_a?(RefAction)
      raise ArgumentError, "a ref action is a Hash {id:, label:, url:}" unless value.is_a?(Hash)

      value = value.transform_keys(&:to_sym)
      new(id: value[:id], label: value[:label], url: value[:url])
    end
  end

  # A ref as data: a kind, a target, an optional label and the plugins'
  # extra actions (RefAction), for a UI to trace it. The kind's own actions
  # are the UI's (a file ref keeps the editor, show in turn and copy), so
  # +actions+ only adds to them.
  # - +kind+ "file": +target+ {path:, line:, end_line:}, the lines only when
  #   positive, the end only past the start (FileRef's shape).
  # - Any other kind ("issue", "commit", …): +target+ {id:}. The page shows
  #   its +label+ (or the text it matched) and runs its first action.
  # +to_h+ is the shape the page reads (refs.js bindRef). FileRef stays the
  # rows' own ref; this is the one a plugin gives.
  Ref = Data.define(:kind, :target, :label, :actions) do
    # @raise [ArgumentError] a kind that isn't a short lowercase word, a
    #   target without its kind's key, a non-list of actions or a bad action
    def initialize(kind:, target:, label: nil, actions: [])
      kind = kind.to_s
      raise ArgumentError, "a ref's kind is a short lowercase word (#{kind.inspect})" unless Ref::KIND.match?(kind)
      raise ArgumentError, "a ref's actions are a list" unless actions.nil? || actions.is_a?(Array)

      label = label.to_s.strip
      super(kind: kind, target: Ref.target_for(kind, target), label: label.empty? ? nil : label,
            actions: Array(actions).map { |action| RefAction.from(action) }.freeze)
    end

    # @return [Hash] {kind:, target:, label:, actions: [{id:, label:, url:}]},
    #   no label when there is none
    def to_h = { kind: kind, target: target, label: label, actions: actions.map(&:to_h) }.compact
  end

  class Ref
    KIND = /\A[a-z][a-z0-9_-]{0,31}\z/
    # FileRef::KIND, not required here (it loads the file tools).
    FILE = "file"

    # A plugin's {kind:, target:, label:, actions:} (String or Symbol keys).
    # @raise [ArgumentError] as +new+
    def self.from(value)
      raise ArgumentError, "a ref is a Hash {kind:, target:, label:, actions:}" unless value.is_a?(Hash)

      value = value.transform_keys(&:to_sym)
      new(kind: value[:kind], target: value[:target], label: value[:label], actions: value[:actions] || [])
    end

    # +kind+'s target from +raw+: a file's path and lines, any other kind's id.
    # @raise [ArgumentError] not a Hash, or without the kind's key
    def self.target_for(kind, raw)
      raise ArgumentError, "a ref's target is a Hash" unless raw.is_a?(Hash)

      raw = raw.transform_keys(&:to_sym)
      kind == FILE ? file_target(raw) : { id: required(raw[:id], :id) }.freeze
    end

    def self.file_target(raw)
      line = positive(raw[:line])
      end_line = line && positive(raw[:end_line])
      { path: required(raw[:path], :path), line: line, end_line: end_line && end_line > line ? end_line : nil }.compact.freeze
    end
    private_class_method :file_target

    def self.required(value, key)
      value = value.to_s.strip
      raise ArgumentError, "a ref's target needs #{key}" if value.empty?

      value
    end
    private_class_method :required

    def self.positive(value)
      number = Integer(value.to_s.strip, exception: false)
      number&.positive? ? number : nil
    end
    private_class_method :positive
  end
end
