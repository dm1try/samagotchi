# frozen_string_literal: true

require_relative "tool_response"
require_relative "tool_ids"
require_relative "token_usage"
require_relative "file_ref"
require_relative "llm_context_edit"
require_relative "llm_context_stale"
require_relative "llm_context_view"
require_relative "tools/memory"

module Samagotchi
  # The working set as the model really has it (the web's rail, chip,
  # popover and footprints overlay it, web.working_set): every file,
  # memory and URL the conversation's tool runs touched, each still +live+,
  # +stale+ (a file changed since the model last saw it) or +forgotten+
  # (nothing of it is still sent under the session's current strategy),
  # with what its content outputs cost in tokens as sent. Pure: built from
  # a conversation, its folder, a strategy and a stat, no session, no
  # Engine. See docs/internals/working-set.md.
  #
  # The runs are the ones that pair with their calls for sure
  # (LLMContextStale.paired_runs, the call as dispatched: aliases resolve
  # as the loops resolve them); a "ran as:" corrected call or an output
  # holding the run separator pairs with none and is left out. A failed run
  # (its output an "Error", a denied call's too) and an interrupted one
  # touch nothing.
  #
  # Content outputs (read, memory_read, web_fetch) carry the tokens and
  # decide forgotten; edit, write and memory_write add ops and stamps only
  # (their content is in the call's arguments, which no strategy cuts).
  # Stale: the item's latest run left a stamp (ToolRun#stamp) and the file
  # now differs from it in mtime or size, or is gone; a run with no stamp
  # (an old session's) never makes a file stale.
  module WorkingSet
    FILE = "file"
    MEMORY = "memory"
    URL = "url"
    LIVE = "live"
    STALE = "stale"
    FORGOTTEN = "forgotten"
    # Forgotten, every output of it by the user's drop (WorkingSetSteer).
    DROPPED = "dropped"

    # One thing the model touched: +kind+ file|memory|url; +key+ a file's
    # absolute path (FileRef), a memory's name, a URL (whitespace
    # collapsed); +state+ live|stale|forgotten|dropped; +tokens+ its content
    # outputs as sent; +ops+ read|edit for a file, read|write for a memory,
    # read for a URL, in first-seen order; +count+ the runs that touched
    # it; +first_id+ the first one's chi id (ToolIds); +pinned+ whether
    # the user pinned it (WorkingSetPin: the model's forget_outputs refuses
    # its outputs), whatever the strategy; +has_drop+ whether any of its
    # content outputs holds the user's applied drop (an undrop has
    # something to take back: a forgotten item too, its other outputs
    # stubbed by the model's layers).
    Item = Data.define(:kind, :key, :state, :tokens, :ops, :count, :first_id, :pinned, :has_drop)

    # An item the user added (/working-set add) that the next turn's note
    # asks the model to read: its identity (+kind+, +key+, as an Item's)
    # and how the note names it (+label+: a file relative to the session's
    # folder, "memory NAME", a URL).
    Add = Data.define(:kind, :key, :label)

    # A projection and the conversation's size (entries) it was built
    # from: the web keeps the newer of an event's and a GET's by it.
    # +adds+: the pending note's adds (#pending_adds), not items yet.
    Snapshot = Data.define(:items, :at, :adds) do
      def initialize(items:, at:, adds: [])
        super
      end

      def empty? = items.empty? && adds.empty?

      # The JSON the event and the route carry: {items: [...], at:}, and
      # adds: [{kind, key, label}] while any is pending.
      def to_h
        hash = { items: items.map(&:to_h), at: at }
        hash[:adds] = adds.map(&:to_h) unless adds.empty?
        hash
      end
    end

    # The turn-start note (WorkingSetSteer#record!): a tail system message
    # of this kind, its ops ([{"op", "kind", "key", "label"}]) in NOTE_OPS.
    NOTE_KIND = "working_set"
    NOTE_OPS = :working_set_ops
    ADD = "add"

    FILE_OPS = { "read" => "read", "edit" => "edit", "write" => "edit" }.freeze
    CONTENT = %w[read memory_read web_fetch].freeze
    MEMORY_READ = Tools::MemoryRead::NAME
    MEMORY_WRITE = Tools::MemoryWrite::NAME
    WEB_FETCH = "web_fetch"
    # A stale stub that an edit (not a later read) made: the model wrote
    # the file, so what it has of it is still current (llm_context.stale_edits).
    BY_EDIT = /superseded by a later (?:edit|write)\z/
    # A partial memory_read's last part (Tools::MemoryRead.call): its first
    # line only, since an orphaned-folder hint may follow on the next.
    MISSING = /\AError: memory not found: ([^\n]*)/

    # What one paired run touched: its item's identity and op, whether its
    # output is content, its stored and sent texts, its stamp.
    Touch = Data.define(:kind, :key, :op, :content, :run, :sent, :share)
    private_constant :Touch

    module_function

    # @param conversation [Array<Hash>] the stored entries (symbol keys at
    #   the top, as Session.load has them)
    # @param cwd [String, nil] the session's folder: a relative path's base
    # @param strategy [Symbol, Array<Symbol>] :none or the layers, as
    #   LLMContextView takes it (the session's current one)
    # @param stat [#call] File.stat, or a stand-in (specs)
    # @param pins [Array<WorkingSetPin>] the session's pins
    # @return [Snapshot]
    def build(conversation, cwd:, strategy:, stat: File.method(:stat), pins: [])
      conversation = Array(conversation)
      view = LLMContextView.new(strategy: strategy)
      pinned = pins.to_set { |pin| [pin.kind, pin.key] }
      items = all_touches(conversation, cwd, view).group_by { |touch| [touch.kind, touch.key] }.map do |(kind, key), group|
        item(kind, key, group, conversation, view, stat, pinned.include?([kind, key]))
      end
      Snapshot.new(items: items, at: conversation.size, adds: pending_adds(conversation))
    end

    # The index of the note the next turn will send (one after the last
    # turn's entries: only system messages follow it), or nil.
    def pending_note_index(messages)
      (messages.size - 1).downto(0) do |index|
        message = messages[index]
        return nil unless message.is_a?(Hash) && message[:role].to_s == "system"
        return index if message[:kind].to_s == NOTE_KIND
      end
      nil
    end

    # The ops the pending note lists ([{"op", "kind", "key", "label"}]).
    def pending_ops(messages)
      messages = Array(messages)
      index = pending_note_index(messages)
      index ? Array(messages[index][NOTE_OPS]).select { |op| op.is_a?(Hash) } : []
    end

    # The items the user added since the last turn, which the next turn's
    # note asks the model to read.
    # @return [Array<Add>]
    def pending_adds(messages)
      pending_ops(messages).select { |op| op["op"] == ADD }.map do |op|
        Add.new(kind: op["kind"].to_s, key: op["key"].to_s, label: op["label"].to_s)
      end
    end

    # One content output (read, memory_read, web_fetch) of an item: its
    # chi +id+ (ToolIds), the +index+ of the tool_response entry holding
    # it, whether the id is +derived+ (a legacy entry's: nothing can name
    # it) and whether the model is still +sent+ it under the strategy.
    # +shared_with+: the other names a memory_read of several names holds in the
    # same output (an op on the output acts on them too), else empty.
    Output = Data.define(:id, :index, :derived, :sent, :shared_with)

    # The content outputs of the item +kind+/+key+ (#build's identity: a
    # file's absolute path, a memory's name, a URL), in conversation
    # order, by the same pairing #build uses, so what acts on an item's
    # outputs and the projection never disagree. Edit-only items have
    # none. A memory_read of several names is one output of each.
    # @return [Array<Output>]
    def outputs_of(conversation, kind:, key:, strategy:, cwd:)
      conversation = Array(conversation)
      view = LLMContextView.new(strategy: strategy)
      all_touches(conversation, cwd, view).filter_map do |touch|
        next unless touch.content && touch.kind == kind && touch.key == key

        ref = touch.run.ref
        Output.new(id: ref.id, index: touch.run.index, derived: ref.derived?,
                   sent: still_sent?(touch, conversation, view), shared_with: shared_with(touch, key))
      end
    end

    # The ids of the content outputs of the items +pins+ name (the ones
    # the model's forget_outputs refuses), by the same pairing as #build.
    # @param pins [Array<WorkingSetPin>]
    # @return [Set<String>]
    def pinned_ids(conversation, pins:, cwd:)
      return Set.new if pins.empty?

      conversation = Array(conversation)
      pinned = pins.to_set { |pin| [pin.kind, pin.key] }
      touches = all_touches(conversation, cwd, LLMContextView.new(strategy: LLMContextView::NONE))
      touches.select { |touch| touch.content && pinned.include?([touch.kind, touch.key]) }.to_set { |touch| touch.run.ref.id }
    end

    # Every paired run's touches, with what +view+ sends of its output.
    def all_touches(conversation, cwd, view)
      stored = LLMContextStale.paired_runs(conversation)
      # Under none with no drop the view sends the conversation as it is.
      messages = view.messages(conversation)
      sent = if messages.equal?(conversation)
               {}
             else
               LLMContextStale.paired_runs(messages).to_h { |run| [run.ref.id, run.text] }
             end
      stored.flat_map { |run| touches(run, sent.fetch(run.ref.id, run.text), cwd) }
    end

    # The items +run+ touched (none when it failed or was interrupted).
    def touches(run, sent, cwd)
      name = run.call[:name].to_s
      return [] if failed?(run.text)

      base = { run: run, sent: sent, content: CONTENT.include?(name), share: 1 }
      if FILE_OPS.key?(name)
        path = FileRef.for(name, run.call, cwd: cwd)&.path
        path ? [Touch.new(kind: FILE, key: path, op: FILE_OPS[name], **base)] : []
      elsif name == MEMORY_READ
        names = found_names(run)
        names.map { |memory| Touch.new(kind: MEMORY, key: memory, op: "read", **base.merge(share: names.size)) }
      elsif name == MEMORY_WRITE
        memory = run.call[:path].to_s.strip
        memory.empty? ? [] : [Touch.new(kind: MEMORY, key: memory, op: "write", **base)]
      elsif name == WEB_FETCH
        url = run.call[:content].to_s.gsub(/\s+/, " ").strip
        url.empty? ? [] : [Touch.new(kind: URL, key: url, op: "read", **base)]
      else
        []
      end
    end

    # LLMContextStale's failed rule (an "Error" after the "[name]" lead; a
    # denied call's "Error:" too), or an interrupted run.
    def failed?(text)
      ToolResponse.interrupted_text?(text) || text.sub(ToolResponse::LEAD, "").lstrip.start_with?("Error")
    end

    # The other names +touch+'s output holds (a memory_read of several).
    def shared_with(touch, key) = touch.share > 1 ? found_names(touch.run) - [key] : []

    # A memory_read's names (Tools::MemoryRead.parse_names: none for the
    # index listing), less the ones its output says weren't found.
    def found_names(run)
      names = Tools::MemoryRead.parse_names(run.call[:content].to_s)
      last = run.text.split(ToolResponse::SEPARATOR).last.to_s
      missing = (match = MISSING.match(last)) ? match[1].split(",").map(&:strip) : []
      names - missing
    end

    def item(kind, key, group, conversation, view, stat, pinned)
      first = group.first
      contents = group.select(&:content)
      tokens = contents.sum { |touch| touch.sent.length / TokenUsage::CHARS_PER_TOKEN / touch.share }.ceil
      state = if contents.any? && contents.none? { |touch| still_sent?(touch, conversation, view) }
                contents.all? { |touch| dropped?(touch, conversation) } ? DROPPED : FORGOTTEN
              elsif kind == FILE && changed?(key, group.last.run, conversation, stat)
                STALE
              else
                LIVE
              end
      Item.new(kind: kind, key: key, state: state, tokens: tokens, ops: group.map(&:op).uniq, count: group.size,
               first_id: first.run.ref.id, pinned: pinned, has_drop: contents.any? { |touch| dropped?(touch, conversation) })
    end

    # Whether the model is still sent +touch+'s output: whole (with the
    # forget layer's "[#id] " after its lead, when it shows ids), or a
    # stub that keeps some of it: a forget's kept lines, a stale stub an
    # edit made (the model wrote the file).
    def still_sent?(touch, conversation, view)
      stored = touch.run.text
      sent = touch.sent
      return true if sent == stored || sent == with_id(stored, touch.run.ref.id)

      edit = LLMContextEdit.on(conversation[touch.run.index])[touch.run.ref.id]
      return true unless edit && view.sends?(edit)

      edit.kind == :forget ? edit.keep? : edit.note.match?(BY_EDIT)
    end

    # Whether +touch+'s output holds the user's applied drop.
    def dropped?(touch, conversation)
      edit = LLMContextEdit.on(conversation[touch.run.index])[touch.run.ref.id]
      !edit.nil? && edit.kind == LLMContextEdit::DROP && edit.applied?
    end

    def with_id(text, id)
      match = text.match(ToolResponse::LEAD)
      match ? "#{match[0]}[##{id}] #{match.post_match}" : nil
    end

    # Whether the file at +path+ differs from +run+'s stamp (the item's
    # latest run): no stamp, not changed.
    def changed?(path, run, conversation, stat)
      stamp = stamp_of(conversation[run.index], run.ref.run)
      return false unless stamp

      now = stat.call(path)
      mtime_ns = (now.mtime.to_i * 1_000_000_000) + now.mtime.nsec
      mtime_ns != field(stamp, :mtime_ns) || now.size != field(stamp, :size)
    rescue SystemCallError
      # Gone (or unreadable): not what the model saw.
      true
    end

    # +entry+'s tool_stamps at the run's place, a Hash with symbol keys
    # (live) or string keys (after a reload); nil when none.
    def stamp_of(entry, place)
      stamps = entry[:tool_stamps]
      stamp = stamps.is_a?(Array) ? stamps[place] : nil
      stamp.is_a?(Hash) && field(stamp, :mtime_ns) ? stamp : nil
    end

    def field(hash, key) = hash.key?(key) ? hash[key] : hash[key.to_s]

    private_class_method :all_touches, :touches, :failed?, :found_names, :shared_with, :item, :still_sent?, :dropped?, :with_id, :changed?, :stamp_of, :field
  end
end
