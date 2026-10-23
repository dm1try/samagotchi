# frozen_string_literal: true

require "did_you_mean"

module Samagotchi
  module Commands
    # The slash (and bang) commands a session knows, in lookup order: the
    # built-ins SessionCommands registers, and later the ones bundles add.
    #
    # An entry the UI runs itself (/stats, /exit, …) is +local+: it is listed
    # for Tab completion and help, and #lookup never returns it.
    class Registry
      # What a line does while a turn runs: runs now on its own thread
      # (:anytime), runs after the turn ends (:queue), or is refused
      # (:refuse, "busy").
      MID_TURN = %i[anytime queue refuse].freeze

      # A plugin's pill in the web's selection bar (chi.annotation,
      # docs/plugins.md): it prepares +line+ (a command line of its entry)
      # and +template+ filled from the selection, and fills the composer
      # with it, or sends it at once (+sends+).
      Annotation = Data.define(:label, :line, :template, :sends) do
        # As a listing names it ({label:, line:, template:, send:}).
        def to_h = { label: label, line: line, template: template, send: sends }
      end

      # @!attribute id [Symbol] the entry's key (:model, :rollback, …)
      # @!attribute name [String] "/model", "!rollback", …
      # @!attribute mid_turn [Symbol, #call] what a line of it does while a
      #   turn runs (MID_TURN): a symbol, or a lambda line (stripped) → one
      # @!attribute local [Boolean] the UI runs it; completion and help only
      # @!attribute uis [Array<Symbol>, nil] a local entry's UIs (:repl,
      #   :attached, :web) for completion and /help; nil means every UI
      #   (for a local entry, every terminal)
      # @!attribute match [#call] line (stripped) → whether it is this command
      # @!attribute handler [Proc, nil] runs it; SessionCommands instance_execs
      #   a built-in's with the line, and calls a bundle's with the text
      #   after the name
      # @!attribute source [String] "core", or the bundle that added it
      # @!attribute annotations [Array<Annotation>] its selection-bar pills
      #   (a bundle's command; empty for the rest)
      Entry = Struct.new(:id, :name, :description, :mid_turn, :local, :uis, :match, :handler, :source, :annotations,
                         keyword_init: true) do
        def match?(text) = match.call(text)

        # Whether every line of it runs at once, a turn running or not (D8).
        def anytime = mid_turn == :anytime

        # @param text [String] a line of it, stripped
        # @return [Symbol] one of MID_TURN
        def mid_turn_for(text) = mid_turn.respond_to?(:call) ? mid_turn.call(text) : mid_turn

        # How a listing names #mid_turn: "depends" when it is the line's.
        def mid_turn_label = mid_turn.respond_to?(:call) ? "depends" : mid_turn.to_s
        def slash? = name.start_with?("/")
        def in_ui?(ui) = uis.nil? || uis.include?(ui)
      end

      # @param entries [Array<Entry>] taken as they are, in order (.from_listing)
      def initialize(entries: [])
        @entries = []
        entries.each { |entry| add(entry) }
      end

      # A UI without an Engine (attached) learns the session's commands from
      # its snapshot (#listing): +base+'s entries as they are (their match
      # and ids), then each listed one +base+ lacks, matched by its name
      # (a bundle's command; the worker runs it).
      # @param listing [Array<Hash>] #listing, with String or Symbol keys
      # @return [Registry]
      def self.from_listing(listing, base:)
        registry = new(entries: base.entries)
        known = base.entries.map(&:name)
        Array(listing).each do |item|
          item = item.transform_keys(&:to_sym)
          name = item[:name].to_s
          next if name.empty? || known.include?(name)

          known << name
          registry.register(name, item[:description].to_s, mid_turn: listed_mid_turn(item), local: item[:local] == true,
                                                           uis: item[:uis]&.map(&:to_sym), source: item[:source] || "core")
        end
        registry
      end

      # A listed entry's #mid_turn: its mid_turn, else (an older worker's
      # listing) its anytime. "depends" (a line's own, which only the
      # worker's entry knows) and anything unknown are :refuse: the UI
      # sends the line and the worker decides.
      def self.listed_mid_turn(item)
        label = item[:mid_turn]&.to_sym
        return label if MID_TURN.include?(label)
        return :refuse if label

        item[:anytime] == true ? :anytime : :refuse
      end
      private_class_method :listed_mid_turn

      # A name is taken once, with one exception: core may give a name two
      # entries, one the UIs run (local) and one the session runs, each with
      # its own match (/recap shows in a UI, /recap off runs in the worker).
      # #listing then has the name twice, /help and Tab once.
      # @param anytime [Boolean] mid_turn: :anytime (a bundle's command)
      # @param mid_turn [Symbol, #call, nil] see Entry; nil takes +anytime+
      # @param match [#call, nil] the default matches the name alone or the
      #   name, any whitespace (a newline too) and arguments
      # @param annotations [Array<Annotation>] see Entry
      # @return [Entry]
      def register(name, description, id: nil, anytime: false, mid_turn: nil, local: false, uis: nil, match: nil,
                   source: "core", annotations: [], &handler)
        raise ArgumentError, "command #{name} is already registered" unless name_free?(name, local: local, source: source)

        entry = Entry.new(id: id || name.delete_prefix("/").to_sym, name: name, description: description,
                          mid_turn: mid_turn || (anytime ? :anytime : :refuse), local: local, uis: uis, match: match || default_match(name),
                          handler: handler, source: source, annotations: annotations.dup.freeze)
        @entries << entry
        entry
      end

      # @return [Entry, nil] the first entry the session runs that matches +line+
      def lookup(line)
        text = line.to_s.strip
        @entries.find { |entry| !entry.local && entry.match?(text) }
      end

      def command?(line) = !lookup(line).nil?

      # Whether every line of +line+'s command runs at once, a turn running
      # or not (D8). A line whose #mid_turn is :anytime but whose command's
      # isn't always (/model) runs at once only while a turn runs.
      def anytime?(line) = lookup(line)&.anytime == true

      # What +line+ does while a turn runs (MID_TURN); :refuse for a line
      # no command answers.
      # @return [Symbol]
      def mid_turn(line)
        text = line.to_s.strip
        lookup(text)&.mid_turn_for(text) || :refuse
      end

      # A line that is one word: a slash and a name, no spaces, no second
      # slash. `/modle` is one; `/foo bar` and `/usr/bin/env` are not (they
      # are prompts).
      UNKNOWN_COMMAND_WORD = %r{\A/[A-Za-z][A-Za-z0-9_-]*\z}

      # Whether +line+ is a command word no command answers: a typo like
      # `/modle`, which a UI must not send to the model as a prompt.
      def unknown_command_word?(line)
        text = line.to_s.strip
        return false unless UNKNOWN_COMMAND_WORD.match?(text)

        lookup(text).nil? && lookup_local(text).nil?
      end

      # What a UI shows for an unknown command word, or nil when +line+ is
      # not one: `Unknown command /modle. Did you mean /model? /help lists
      # the commands.` The "Did you mean" part needs a close name among the
      # entries (DidYouMean::SpellChecker).
      def unknown_command_hint(line)
        return nil unless unknown_command_word?(line)

        text = line.to_s.strip
        close = DidYouMean::SpellChecker.new(dictionary: @entries.map(&:name)).correct(text).first
        "Unknown command #{text}. #{"Did you mean #{close}? " if close}/help lists the commands."
      end

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
      # @return [Array<Hash>] {name:, description:, anytime:, mid_turn:,
      #   local:, uis:, source:} per entry, in registration order; anytime
      #   is true only when every line is (mid_turn "anytime"). An entry
      #   with annotations adds annotations: [Annotation#to_h] (the web's
      #   selection bar; other UIs ignore the key).
      def listing
        @entries.map do |entry|
          item = { name: entry.name, description: entry.description, anytime: entry.anytime,
                   mid_turn: entry.mid_turn_label, local: entry.local ? true : false, uis: entry.uis&.map(&:to_s), source: entry.source }
          item[:annotations] = entry.annotations.map(&:to_h) if entry.annotations&.any?
          item
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

      def name_free?(name, local:, source:)
        taken = @entries.select { |entry| entry.name == name }
        return true if taken.empty?

        source == "core" && taken.size == 1 && taken.first.source == "core" && !taken.first.local != !local
      end

      def default_match(name)
        after = /\A#{Regexp.escape(name)}\s/
        ->(text) { text == name || after.match?(text) }
      end
    end
  end
end
