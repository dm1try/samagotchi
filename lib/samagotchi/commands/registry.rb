# frozen_string_literal: true

module Samagotchi
  module Commands
    # The slash (and bang) commands a session knows, in lookup order: the
    # built-ins SessionCommands registers, and later the ones bundles add.
    #
    # An entry the UI runs itself (/stats, /exit, …) is +local+: it is listed
    # for Tab completion and help, and #lookup never returns it.
    class Registry
      # @!attribute id [Symbol] what SessionCommands.kind_of_line answers
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

      # @return [Array<Entry>] every entry, in registration order
      def entries = @entries.dup

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

      def default_match(name)
        ->(text) { text == name || text.start_with?("#{name} ") }
      end
    end
  end
end
