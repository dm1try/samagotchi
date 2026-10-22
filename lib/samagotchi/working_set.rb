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

    # One thing the model touched: +kind+ file|memory|url; +key+ a file's
    # absolute path (FileRef), a memory's name, a URL (whitespace
    # collapsed); +state+ live|stale|forgotten; +tokens+ its content
    # outputs as sent; +ops+ read|edit for a file, read|write for a memory,
    # read for a URL, in first-seen order; +count+ the runs that touched
    # it; +first_id+ the first one's chi id (ToolIds).
    Item = Data.define(:kind, :key, :state, :tokens, :ops, :count, :first_id)

    # A projection and the conversation's size (entries) it was built
    # from: the web keeps the newer of an event's and a GET's by it.
    Snapshot = Data.define(:items, :at) do
      def empty? = items.empty?

      # The JSON the event and the route carry: {items: [...], at:}.
      def to_h = { items: items.map(&:to_h), at: at }
    end

    FILE_OPS = { "read" => "read", "edit" => "edit", "write" => "edit" }.freeze
    CONTENT = %w[read memory_read web_fetch].freeze
    MEMORY_READ = Tools::MemoryRead::NAME
    MEMORY_WRITE = Tools::MemoryWrite::NAME
    WEB_FETCH = "web_fetch"
    # A stale stub that an edit (not a later read) made: the model wrote
    # the file, so what it has of it is still current (llm_context.stale_edits).
    BY_EDIT = /superseded by a later (?:edit|write)\z/
    # A partial memory_read's last part (Tools::MemoryRead.call).
    MISSING = /\AError: memory not found: (.*)\z/m

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
    # @return [Snapshot]
    def build(conversation, cwd:, strategy:, stat: File.method(:stat))
      conversation = Array(conversation)
      view = LLMContextView.new(strategy: strategy)
      stored = LLMContextStale.paired_runs(conversation)
      sent = if view.none?
               {}
             else
               LLMContextStale.paired_runs(view.messages(conversation)).to_h { |run| [run.ref.id, run.text] }
             end
      touches = stored.flat_map { |run| touches(run, sent.fetch(run.ref.id, run.text), cwd) }
      items = touches.group_by { |touch| [touch.kind, touch.key] }.map do |(kind, key), group|
        item(kind, key, group, conversation, view, stat)
      end
      Snapshot.new(items: items, at: conversation.size)
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

    # A memory_read's names (Tools::MemoryRead.parse_names: none for the
    # index listing), less the ones its output says weren't found.
    def found_names(run)
      names = Tools::MemoryRead.parse_names(run.call[:content].to_s)
      last = run.text.split(ToolResponse::SEPARATOR).last.to_s
      missing = (match = MISSING.match(last)) ? match[1].split(",").map(&:strip) : []
      names - missing
    end

    def item(kind, key, group, conversation, view, stat)
      first = group.first
      contents = group.select(&:content)
      tokens = contents.sum { |touch| touch.sent.length / TokenUsage::CHARS_PER_TOKEN / touch.share }.ceil
      state = if contents.any? && contents.none? { |touch| still_sent?(touch, conversation, view) }
                FORGOTTEN
              elsif kind == FILE && changed?(key, group.last.run, conversation, stat)
                STALE
              else
                LIVE
              end
      Item.new(kind: kind, key: key, state: state, tokens: tokens, ops: group.map(&:op).uniq, count: group.size,
               first_id: first.run.ref.id)
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
      return true unless edit&.applied? && view.layers.include?(edit.kind)

      edit.kind == :forget ? edit.keep? : edit.note.match?(BY_EDIT)
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

    private_class_method :touches, :failed?, :found_names, :item, :still_sent?, :with_id, :changed?, :stamp_of, :field
  end
end
