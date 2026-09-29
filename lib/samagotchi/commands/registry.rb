# frozen_string_literal: true

module Samagotchi
  module Commands
    # The slash (and bang) commands a session knows, in lookup order: the
    # built-ins SessionCommands registers, and later the ones bundles add.
    #
    # An entry the UI runs itself (/stats, /exit, …) is +local+: it is listed
    # for Tab completion and help, and #lookup never returns it.
    class Registry
      # @!attribute id [Symbol] the entry's key (:model, :rollback, …)
      # @!attribute name [String] "/model", "!rollback", …
      # @!attribute anytime [Boolean] may run while a turn runs
      # @!attribute local [Boolean] the UI runs it; completion and help only
      # @!attribute uis [Array<Symbol>, nil] a local entry's UIs (:repl,
      #   :attached) for completion; nil means every UI
      # @!attribute match [#call] line (stripped) → whether it is this command
      # @!attribute handler [Proc, nil] runs it; SessionCommands instance_execs
      #   a built-in's with the line, and calls a bundle's with the text
      #   after the name
      # @!attribute source [String] "core", or the bundle that added it
      Entry = Struct.new(:id, :name, :description, :anytime, :local, :uis, :match, :handler, :source,
                         keyword_init: true) do
        def match?(text) = match.call(text)
        def slash? = name.start_with?("/")
        def in_ui?(ui) = uis.nil? || uis.include?(ui)
      end

      def initialize
        @entries = []
      end

      # A UI without an Engine (attached) learns the session's commands from
      # its snapshot (#listing): +base+'s entries as they are (their match
      # and ids), then each listed one +base+ lacks, matched by its name
      # (a bundle's command; the worker runs it).
      # @param listing [Array<Hash>] #listing, with String or Symbol keys
      # @return [Registry]
      def self.from_listing(listing, base:)
        registry = new
        base.entries.each { |entry| registry.send(:add, entry) }
        known = base.entries.map(&:name)
        Array(listing).each do |item|
          item = item.transform_keys(&:to_sym)
          name = item[:name].to_s
          next if name.empty? || known.include?(name)

          known << name
          registry.register(name, item[:description].to_s, anytime: item[:anytime] == true, local: item[:local] == true,
                                                           uis: item[:uis]&.map(&:to_sym), source: item[:source] || "core")
        end
        registry
      end

      # @param match [#call, nil] the default matches the name alone or the
      #   name, a space and arguments
      # @return [Entry]
      def register(name, description, id: nil, anytime: false, local: false, uis: nil, match: nil,
                   source: "core", &handler)
        raise ArgumentError, "command #{name} is already registered" if @entries.any? { |entry| entry.name == name }

        entry = Entry.new(id: id || name.delete_prefix("/").to_sym, name: name, description: description,
                          anytime: anytime, local: local, uis: uis, match: match || default_match(name),
                          handler: handler, source: source)
        @entries << entry
        entry
      end

      # @return [Entry, nil] the first entry the session runs that matches +line+
      def lookup(line)
        text = line.to_s.strip
        @entries.find { |entry| !entry.local && entry.match?(text) }
      end

      def command?(line) = !lookup(line).nil?

      # @return [Entry, nil] the first entry the UI runs itself (local) that
      #   matches +line+, whatever its uis (a UI answers the others' too:
      #   the REPL's /detach note)
      def lookup_local(line)
        text = line.to_s.strip
        @entries.find { |entry| entry.local && entry.match?(text) }
      end

      # @return [Array<Entry>] every entry, in registration order
      def entries = @entries.dup

      # What a snapshot tells a UI without an Engine (see .from_listing).
      # @return [Array<Hash>] {name:, description:, anytime:, local:, uis:,
      #   source:} per entry, in registration order
      def listing
        @entries.map do |entry|
          { name: entry.name, description: entry.description, anytime: entry.anytime ? true : false,
            local: entry.local ? true : false, uis: entry.uis&.map(&:to_s), source: entry.source }
        end
      end

      # @param ui [Symbol] :repl or :attached
      # @return [Array<String>] the /names Tab offers in +ui+, sorted
      def completions(ui)
        @entries.select { |entry| entry.slash? && entry.in_ui?(ui) }.map(&:name).uniq.sort
      end

      def freeze
        @entries.freeze
        super
      end

      private

      def add(entry)
        @entries << entry
      end

      def default_match(name)
        ->(text) { text == name || text.start_with?("#{name} ") }
      end
    end
  end
end
