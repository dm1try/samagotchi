# frozen_string_literal: true

require "time"
require_relative "llm_context_edit"
require_relative "llm_context_view"
require_relative "llm_context_apply"
require_relative "token_usage"
require_relative "working_set"
require_relative "working_set_pin"

module Samagotchi
  # The user steering the working set (/working-set, the web's popover):
  # drop an item (every content output of it still sent goes out of the
  # prompt as a stub) and undrop it; pin one (the model's forget_outputs
  # refuses its outputs, LLMContextForget) and unpin it. Pure, on a
  # conversation the caller
  # owns (Engine#clone_messages' copies: an op stores new edits Hashes,
  # LLMContextEdit.store) and runs between turns, so the next turn's first
  # request is the first with the change (prompt caching: one break where
  # the new prompt is fresh anyway).
  #
  # A drop is the user's layer (LLMContextEdit kind :drop, by "user"),
  # saved applied: the view sends it whatever the strategy, none too
  # (LLMContextView#sends?). One edit per id: a drop on an output that
  # holds an edit already (a forget sent whole under none, a staged one, a
  # stale stub) keeps that edit's saved Hash in its +was+, and an undrop
  # puts it back. The outputs are WorkingSet.outputs_of's, the projection's
  # own pairing, so the set and the op never disagree.
  #
  # A pin is the session's (Session#working_set_pins, a WorkingSetPin per
  # item), not an edit: it sends nothing different, so it breaks no cache
  # and survives a strategy switch. Pin and drop exclude each other: a
  # drop asks for an unpin first, and a pin takes a pending drop off (one
  # never sent: free), else asks for an undrop first.
  #
  # An add is a request: the turn-start note asks the model to read the
  # item (read, memory_read, web_fetch) before the task, so its output is
  # a real tool run (stamps, ids, forget, the projection), on both loops.
  # Nothing sent changes until then; it costs the model one step. An item
  # the model has whole already is refused; a stale or forgotten one is
  # its refresh. Pending until the next turn sends the note
  # (WorkingSet.pending_adds); an unadd takes it back.
  #
  # Every op since the last turn is listed in one tail system message
  # (kind "working_set", #record!), so the model learns what changed and
  # doesn't read a dropped file again by reflex. An inverse op before the
  # next turn cancels its op there (a drop then an undrop: nothing sent,
  # nothing noted).
  module WorkingSetSteer
    BY = "user"
    NOTE_KIND = WorkingSet::NOTE_KIND
    # The tail note's ops: [{"op", "kind", "key", "label"}], until the turn
    # that sends it (the chat loop's kept entries leave the key out).
    OPS = WorkingSet::NOTE_OPS
    NOTE_OPEN = "[WORKING SET: "
    DROP = "drop"
    UNDROP = "undrop"
    PIN = "pin"
    UNPIN = "unpin"
    ADD = WorkingSet::ADD
    UNADD = "unadd"
    INVERSE = { DROP => UNDROP, UNDROP => DROP, PIN => UNPIN, UNPIN => PIN, ADD => UNADD, UNADD => ADD }.freeze
    MEMORY_PREFIX = "memory:"
    URL = %r{\A[a-z][a-z0-9+.-]*://}i

    # Why an op can't be done: the one place each refusal's words live
    # (/working-set and forget_outputs add context only).
    class Refused < StandardError
      MESSAGES = {
        dropped: "dropped by the user",
        pinned_by_user: "pinned by the user: it stays in your context",
        unpin_first: "pinned by the user: unpin it first",
        undrop_first: "dropped by the user: undrop it first",
        already_pinned: "already pinned",
        not_pinned: "not pinned",
        not_in_set: "not in the working set",
        only_edited: "nothing to drop: only edited or written (no read of it is sent)",
        derived: "nothing to drop: an older session's output that chi can't name",
        already_dropped: "already dropped",
        not_sent: "nothing to drop: none of it is sent now (forgotten or stubbed)",
        not_dropped: "not dropped",
        no_file: "no such file",
        directory: "a directory: add its files",
        no_memory: "no such memory",
        bad_memory: "not a memory name (no /, \\ or ..)",
        not_http: "not an http(s) URL: web_fetch can't fetch it",
        already_sent: "already in the model's context (sent whole): nothing to add",
        already_added: "already added: the next turn reads it",
        not_added: "not added (no add of it is pending)"
      }.freeze

      # @return [Symbol] a key of MESSAGES
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(MESSAGES.fetch(reason))
      end

      # The words for +reason+, for a caller that only reports it.
      def self.text(reason) = MESSAGES.fetch(reason)
    end

    # What a KEY names: an item's identity (WorkingSet's kind and key) and
    # how replies name it (a file relative to the session's folder).
    Target = Data.define(:kind, :key, :label)

    # What an op did: the ids it changed, and the chars it frees (a drop)
    # and the tail the server reads again from its earliest entry on.
    # +free+: an undrop that took back a drop never sent (nothing changes),
    # a pin or an unpin (nothing sent changes). +undone+: the pending drop
    # a pin took off (a Done), else nil. +shared_with+: the other memories a
    # memory_read of several names holds in an output the op acted on (the
    # op acts on that output whole, so on them too).
    Done = Data.define(:target, :op, :ids, :freed_chars, :tail_chars, :free, :undone, :shared_with) do
      def initialize(undone: nil, shared_with: [], **fields) = super
    end

    module_function

    # A word quoted ("…" or '…'): runs to its closing quote, spaces and
    # all; a backslash escapes the quote or itself. Else a bare word.
    WORD = /\G\s*(?:"((?:[^"\\]|\\.)*)"?|'((?:[^'\\]|\\.)*)'?|(\S+))/m
    # What a quoted word unescapes (\" \' \\); any other backslash stays.
    ESCAPE = /\\(["'\\])/
    # A word that needs quoting on a line: whitespace, or a leading quote.
    QUOTE = /\s|\A["']/

    # The KEY words of a /working-set line (what follows the verb):
    # whitespace-separated, a quoted word keeps its spaces ("my dir/a.rb").
    # An unclosed quote runs to the end. The web's working_set.js
    # (steerWords) reads lines the same way.
    # @return [Array<String>]
    def words(text)
      text.to_s.scan(WORD).filter_map do |double, single, bare|
        quoted = double || single
        quoted ? quoted.gsub(ESCAPE, '\\1') : bare
      end.reject(&:empty?)
    end

    # +word+ as a line names it: quoted when it has whitespace or starts
    # with a quote (#words reads it back), else as it is.
    def quote(word)
      word = word.to_s
      word.match?(QUOTE) ? %("#{word.gsub(/["\\]/) { |char| "\\#{char}" }}") : word
    end

    # +word+ (a path, absolute or the session's folder's; memory:NAME; a
    # URL) as a Target.
    def target(word, cwd:)
      word = word.to_s.strip
      if word.start_with?(MEMORY_PREFIX)
        name = word.delete_prefix(MEMORY_PREFIX).strip
        Target.new(kind: WorkingSet::MEMORY, key: name, label: "memory #{name}")
      elsif word.match?(URL)
        url = word.gsub(/\s+/, " ")
        Target.new(kind: WorkingSet::URL, key: url, label: url)
      else
        path = File.expand_path(word, cwd.to_s.empty? ? Dir.pwd : cwd)
        Target.new(kind: WorkingSet::FILE, key: path, label: relative(path, cwd))
      end
    end

    # A path as replies show it: below +cwd+ relative, else as it is.
    def relative(path, cwd)
      base = "#{cwd.to_s.chomp("/")}/"
      !cwd.to_s.empty? && path.start_with?(base) ? path.delete_prefix(base) : path
    end

    # Drops +target+'s content outputs that are still sent under
    # +strategy+ (the next turn's: LLMContextView's form), saving an applied
    # :drop on each.
    # +pins+: the session's (a pinned item asks for an unpin first).
    # @return [Done]
    # @raise [Refused]
    def drop(conversation, target, strategy:, cwd:, pins: [], now: Time.now.utc.iso8601(3))
      raise Refused, :unpin_first if pinned?(pins, target)

      outputs = WorkingSet.outputs_of(conversation, kind: target.kind, key: target.key, strategy: strategy, cwd: cwd)
      raise Refused, (known?(conversation, target, strategy, cwd) ? :only_edited : :not_in_set) if outputs.empty?

      named = outputs.reject(&:derived)
      raise Refused, :derived if named.empty?
      raise Refused, :already_dropped if named.all? { |output| drop_of(conversation, output) }

      sent = named.select(&:sent)
      raise Refused, :not_sent if sent.empty?

      edits = sent.map do |output|
        was = LLMContextEdit.on(conversation[output.index])[output.id]
        [output.index, LLMContextEdit.new(id: output.id, kind: LLMContextEdit::DROP, note: "", by: BY, staged_at: now,
                                          applied_at: now, was: was&.to_h)]
      end
      freed, tail = LLMContextApply.weigh(conversation, layers: layers(strategy), edits: edits)
      edits.each { |index, edit| LLMContextEdit.store(conversation[index], edit) }
      Done.new(target: target, op: DROP, ids: edits.map { |_, edit| edit.id }, freed_chars: freed, tail_chars: tail,
               free: false, shared_with: shared_with(sent))
    end

    # Takes +target+'s drops off, putting back what each output held before
    # it (+was+). +sent+: whether the drop reached a request (else the
    # undrop is free).
    # @return [Done]
    # @raise [Refused]
    def undrop(conversation, target, strategy:, cwd:, sent: true)
      outputs = WorkingSet.outputs_of(conversation, kind: target.kind, key: target.key, strategy: strategy, cwd: cwd)
      dropped = outputs.filter_map { |output| (edit = drop_of(conversation, output)) && [output, edit] }
      if dropped.empty?
        raise Refused, (outputs.empty? && !known?(conversation, target, strategy, cwd) ? :not_in_set : :not_dropped)
      end

      dropped.each do |output, edit|
        entry = conversation[output.index]
        LLMContextEdit.remove(entry, output.id)
        before = edit.was && LLMContextEdit.from_h(output.id, edit.was)
        LLMContextEdit.store(entry, before) if before
      end
      first = dropped.map { |output, _| output.index }.min
      view = LLMContextView.new(strategy: strategy)
      tail = sent ? LLMContextView.chars(view.messages(conversation)[first..]) : 0
      Done.new(target: target, op: UNDROP, ids: dropped.map { |output, _| output.id }, freed_chars: 0, tail_chars: tail,
               free: !sent, shared_with: shared_with(dropped.map(&:first)))
    end

    # Pins +target+ (an item the set holds; an edit-only one too: its later
    # reads are covered). A drop of it still pending (made since the last
    # turn) is taken off first, free, as Done#undone; a sent one asks for
    # an undrop first. The caller adds the pin (#pinning).
    # @param pins [Array<WorkingSetPin>] the session's
    # @return [Done] +ids+: the outputs the pin holds now
    # @raise [Refused]
    def pin(conversation, pins, target, strategy:, cwd:)
      outputs = WorkingSet.outputs_of(conversation, kind: target.kind, key: target.key, strategy: strategy, cwd: cwd)
      raise Refused, :not_in_set if outputs.empty? && !known?(conversation, target, strategy, cwd)
      raise Refused, :already_pinned if pinned?(pins, target)

      undone = nil
      if outputs.any? { |output| drop_of(conversation, output) }
        raise Refused, :undrop_first unless pending?(conversation, DROP, target)

        undone = undrop(conversation, target, strategy: strategy, cwd: cwd, sent: false)
      end
      named = outputs.reject(&:derived)
      Done.new(target: target, op: PIN, ids: named.map(&:id), freed_chars: 0, tail_chars: 0, free: true, undone: undone,
               shared_with: shared_with(named))
    end

    # Unpins +target+: the model may forget it again. Only the pins are
    # asked (a rollback may have taken the item out of the set).
    # @return [Done]
    # @raise [Refused]
    def unpin(pins, target)
      raise Refused, :not_pinned unless pinned?(pins, target)

      Done.new(target: target, op: UNPIN, ids: [], freed_chars: 0, tail_chars: 0, free: true)
    end

    # Adds +target+: the next turn's note asks the model to read it. +found+
    # answers whether the item exists (a file, a memory; the caller's
    # look). Refused for an item the model is sent whole now (live, a read
    # of it sent), a dropped one (undrop it), and one added already.
    # @param found [#call] target → nil when it exists, else a Refused reason
    # @return [Done]
    # @raise [Refused]
    def add(conversation, target, strategy:, cwd:, found: ->(_) {})
      raise Refused, :already_added if pending?(conversation, ADD, target)

      reason = target.kind == WorkingSet::URL && !target.key.match?(%r{\Ahttps?://}i) ? :not_http : found.call(target)
      raise Refused, reason if reason

      outputs = WorkingSet.outputs_of(conversation, kind: target.kind, key: target.key, strategy: strategy, cwd: cwd)
      raise Refused, :undrop_first if outputs.any? { |output| drop_of(conversation, output) }
      raise Refused, :already_sent if outputs.any?(&:sent) && live?(conversation, target, strategy, cwd)

      Done.new(target: target, op: ADD, ids: [], freed_chars: 0, tail_chars: 0, free: true)
    end

    # Takes back +target+'s pending add (never sent: free).
    # @return [Done]
    # @raise [Refused]
    def unadd(conversation, target)
      raise Refused, :not_added unless pending?(conversation, ADD, target)

      Done.new(target: target, op: UNADD, ids: [], freed_chars: 0, tail_chars: 0, free: true)
    end

    # +pins+ after +done+ (a pin or an unpin). A new frozen Array.
    # @return [Array<WorkingSetPin>]
    def pinning(pins, done)
      pin = WorkingSetPin.new(kind: done.target.kind, key: done.target.key)
      rest = Array(pins).reject { |held| held == pin }
      (done.op == PIN ? rest + [pin] : rest).freeze
    end

    # The other memory names +outputs+ hold (WorkingSet::Output#shared_with).
    def shared_with(outputs) = outputs.flat_map(&:shared_with).uniq

    # Whether +pins+ hold +target+.
    def pinned?(pins, target)
      Array(pins).any? { |pin| pin.kind == target.kind && pin.key == target.key }
    end

    # +output+'s drop (an LLMContextEdit), or nil.
    def drop_of(conversation, output)
      edit = LLMContextEdit.on(conversation[output.index])[output.id]
      edit if edit&.kind == LLMContextEdit::DROP
    end

    # Whether the set holds +target+ at all (an edit-only file does).
    def known?(conversation, target, strategy, cwd)
      WorkingSet.build(conversation, cwd: cwd, strategy: strategy).items.any? do |item|
        item.kind == target.kind && item.key == target.key
      end
    end

    # Whether the set holds +target+ live (not stale, forgotten, dropped).
    def live?(conversation, target, strategy, cwd)
      WorkingSet.build(conversation, cwd: cwd, strategy: strategy).items.any? do |item|
        item.kind == target.kind && item.key == target.key && item.state == WorkingSet::LIVE
      end
    end

    def layers(strategy) = LLMContextView.new(strategy: strategy).layers

    # ── the tail note ───────────────────────────────────────────────────

    # The index of the note the next turn will send, or nil
    # (WorkingSet.pending_note_index).
    def pending_note_index(messages) = WorkingSet.pending_note_index(messages)

    # The ops the pending note lists ([{"op", "kind", "key", "label"}]).
    def pending_ops(messages) = WorkingSet.pending_ops(messages)

    # Whether +target+'s +op+ is pending (made since the last turn).
    def pending?(messages, op, target)
      pending_ops(messages).any? { |entry| same?(entry, op, target) }
    end

    # +messages+ with +done+'s op in the pending note: its inverse there
    # cancels both (the note goes when nothing is left), else it is added
    # (the note appended when there is none). A new Array; the note is a new
    # Hash.
    # @return [Array<Hash>]
    def record!(messages, done)
      index = pending_note_index(messages)
      ops = index ? pending_ops(messages) : []
      inverse = ops.index { |entry| same?(entry, INVERSE.fetch(done.op), done.target) }
      if inverse
        ops = ops.reject.with_index { |_, i| i == inverse }
      else
        ops = ops.reject { |entry| same?(entry, done.op, done.target) }
        ops += [{ "op" => done.op, "kind" => done.target.kind, "key" => done.target.key, "label" => done.target.label }]
      end
      messages = messages.dup
      if ops.empty?
        messages.delete_at(index) if index
      elsif index
        messages[index] = note(ops)
      else
        messages << note(ops)
      end
      messages
    end

    def same?(entry, op, target)
      entry["op"] == op && entry["kind"] == target.kind && entry["key"] == target.key
    end

    # The note listing +ops+: a tail system message, escaped like a context
    # note (Prompt::ESCAPED_KINDS: it carries paths and URLs).
    def note(ops)
      drops = labels(ops, DROP)
      undrops = labels(ops, UNDROP)
      parts = []
      unless drops.empty?
        parts << "the user dropped #{drops.join(", ")} from your context: you are sent a stub instead of " \
                 "#{drops.size == 1 ? "its outputs" : "their outputs"}; read #{drops.size == 1 ? "it" : "them"} again " \
                 "only if the task needs it"
      end
      unless undrops.empty?
        parts << "the user brought back #{undrops.join(", ")}: #{undrops.size == 1 ? "its outputs are" : "their outputs are"} " \
                 "sent whole again"
      end
      pins = labels(ops, PIN)
      parts << "the user pinned #{pins.join(", ")}: forget_outputs won't forget #{pins.size == 1 ? "it" : "them"}" unless pins.empty?
      unpins = labels(ops, UNPIN)
      parts << "the user unpinned #{unpins.join(", ")}: you may forget #{unpins.size == 1 ? "it" : "them"} again" unless unpins.empty?
      adds = ops.select { |entry| entry["op"] == ADD }
      unless adds.empty?
        parts << "the user added #{adds.map { |entry| entry["label"] }.join(", ")} to your context: before anything " \
                 "else, load #{adds.size == 1 ? "it" : "them"} with #{adds.map { |entry| call_of(entry) }.join(", ")}"
      end
      { role: "system", kind: NOTE_KIND, content: "#{NOTE_OPEN}since your last turn #{parts.join("; ")}.]", OPS => ops }
    end

    def labels(ops, op) = ops.select { |entry| entry["op"] == op }.map { |entry| entry["label"] }

    # The tool call that loads an added item, as the note asks for it: a
    # file by its absolute path (a read resolves a relative one against
    # the process's folder, which may not be the session's).
    def call_of(entry)
      tool = { WorkingSet::MEMORY => "memory_read", WorkingSet::URL => "web_fetch" }.fetch(entry["kind"], "read")
      %(#{tool} "#{entry["key"]}")
    end

    # "12.4k tokens", chars/4.
    def k(chars)
      tokens = (chars / TokenUsage::CHARS_PER_TOKEN).ceil
      tokens >= 1000 ? format("%.1fk tokens", tokens / 1000.0) : "#{tokens} tokens"
    end

    private_class_method :relative, :shared_with, :drop_of, :known?, :live?, :layers, :same?, :labels, :call_of
  end
end
