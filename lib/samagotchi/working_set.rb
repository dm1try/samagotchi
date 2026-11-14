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
  # now differs from it in mtime or size, or is gone - for a memory, its
  # entry or the model overlay read with it. A run with no stamp (an old
  # session's) never makes an item stale.
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
    # @param root [String] the system memories folder
    # @return [Snapshot]
    def build(conversation, cwd:, strategy:, stat: File.method(:stat), pins: [],
              root: Tools::MemoryRead.memories_dir("system"))
      conversation = Array(conversation)
      view = LLMContextView.new(strategy: strategy)
      pinned = pins.to_set { |pin| [pin.kind, pin.key] }
      items = all_touches(conversation, cwd, view).group_by { |touch| [touch.kind, touch.key] }.map do |(kind, key), group|
        item(kind, key, group, conversation, view, stat, pinned.include?([kind, key]), root)
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

    # The reader's lines of a read: +first+ and +last+ line of the file it
    # holds (+last+ from the text, so an end_line past the file is clamped,
    # nil for a partial read's), whether it asked for the +whole+ file, and
    # whether it is +partial+ (LLMContextStale.file_run's rule: a head/tail
    # preview of a big file, an output ToolRunner cut): such a read is shown
    # as is, kept out of the file strip and of merging.
    Lines = Data.define(:first, :last, :whole, :partial)

    # A memory_read's file, from its stamp (ToolRunner#memory_stamp): the
    # +scope+ it answered from (project or system), the entry's +path+, the
    # model overlay read with it (+overlay_path+) and that overlay's text as
    # appended to the output (+overlay+; only for a read of one name, the
    # rest of the output its +text+). nil fields for a session saved before
    # memory stamps.
    MemoryPart = Data.define(:scope, :path, :overlay_path, :overlay)

    # One run of an item, as its timeline shows it: the run's chi +tool_id+
    # (ToolIds; +derived+ for a legacy entry's), the tool_response entry's
    # +index+, its global +step+ (LLMContextStale::PairedRun#step), +op+
    # (read, edit, write, memory_read, memory_write, fetch), whether the
    # model is still +sent+ it (#still_sent?: edits and writes always),
    # +dropped+ (the user's applied drop) or +forgotten+ (not sent, not by a
    # drop), and what it holds: a read's +lines+ and +text+ (the output as
    # stored, without its lead or a clamp note), an edit's or write's saved
    # +diff+ (ToolResponse's tool_diffs, never re-diffed: nil for a no-op or
    # a failed snapshot, maybe truncated, {skipped} or {error}), a memory
    # read's whole +text+ with +shared_with+ (the other names it holds) and
    # +memory+, a memory_write's written text, a fetch's text.
    Event = Data.define(:tool_id, :derived, :index, :step, :op, :sent, :dropped, :forgotten, :lines, :diff, :text,
                        :memory, :shared_with) do
      def to_h = super.merge(lines: lines&.to_h, memory: memory&.to_h)
    end

    # An item's timeline: its identity and its events in conversation order
    # (the reader shows them newest first).
    Timeline = Data.define(:kind, :key, :events) do
      def to_h = { kind: kind, key: key, events: events.map(&:to_h) }
    end

    # A stale memory's text now against what the model has: the +text+
    # memory_read would answer now for the names the item's latest read
    # read (nil when an entry is gone), and its +diff+ from what that read
    # sent (TextDiff, EditPreview's shape; "" text for no change).
    Now = Data.define(:text, :diff, :gone)

    OPS = { "read" => "read", "edit" => "edit", "write" => "write", MEMORY_READ => "memory_read",
            MEMORY_WRITE => "memory_write", WEB_FETCH => "fetch" }.freeze
    # A range read past the file's end says so after its lines (Tools::Read).
    CLAMP_NOTE = /\n\[read: end_line \d+ exceeds \d+ lines; returning lines \d+-\d+\]\z/
    # The timeline of the item +kind+/+key+ (#build's identity): every run
    # that touched it, edits and writes too, by the same walk #build and
    # #outputs_of use (one all_touches), so the projection, the steer and
    # the timeline never disagree on which runs belong to an item. An
    # unknown key has none. Pure; the route adds #memory_now on request.
    # @return [Timeline]
    def timeline_of(conversation, kind:, key:, strategy:, cwd:)
      conversation = Array(conversation)
      view = LLMContextView.new(strategy: strategy)
      events = all_touches(conversation, cwd, view).filter_map do |touch|
        next unless touch.kind == kind && touch.key == key

        event(touch, conversation, view, cwd)
      end
      Timeline.new(kind: kind, key: key, events: events)
    end

    # What the memory +key+'s latest memory_read would answer now, and its
    # diff from what that read sent; nil when no read of it has a stamp (a
    # session saved before memory stamps). +root+: the memories folder
    # (MemoryPaths.system_dir: the projects' folders are under it); a stamped
    # or resolved path outside it is never read, nil then. +read+: File.read,
    # or a stand-in.
    # @return [Now, nil]
    def memory_now(conversation, key:, strategy:, cwd:, root:, read: ->(path) { File.read(path, encoding: "UTF-8") })
      conversation = Array(conversation)
      view = LLMContextView.new(strategy: strategy)
      touch = all_touches(conversation, cwd, view).reverse.find do |candidate|
        candidate.kind == MEMORY && candidate.key == key && candidate.op == "read"
      end
      entries = touch && memory_entries(touch.run, conversation)
      return nil unless entries

      names = found_names(touch.run)
      current_entries = names.map do |name|
        entry = entries[name]
        return nil unless entry.is_a?(Hash)

        if resolution_metadata?(entry)
          resolved = resolve_memory(name, entry, system_dir: root)
          if resolved != :stamped_paths
            return Now.new(text: nil, diff: nil, gone: true) unless resolved

            entry = resolved_memory_entry(resolved)
          end
        end
        return nil unless memory_paths?(entry, root)

        entry
      end

      had = body_of(touch.run.text)
      bodies = names.zip(current_entries).map { |name, entry| memory_body(name, entry, read) }
      return Now.new(text: nil, diff: nil, gone: true) if bodies.any?(&:nil?)

      # Here, not at load: the testing kit loads WorkingSet and keeps a file budget (sandbox_spec).
      require_relative "text_diff"
      last = had.split(Tools::MemoryRead::SEPARATOR).last.to_s
      bodies << last if last.match?(MISSING)
      now = bodies.join(Tools::MemoryRead::SEPARATOR)
      Now.new(text: now, diff: TextDiff.unified(had, now).merge(new_file: false), gone: false)
    end

    # Whether a stamp entry's file and its overlay's are .md files inside the
    # memories folder +root+ (a stamp is the session file's: never read
    # what it names elsewhere).
    def memory_paths?(entry, root)
      overlay = field(entry, :overlay)
      paths = [field(entry, :path), overlay.is_a?(Hash) ? field(overlay, :path) : nil].compact
      base = File.join(File.expand_path(root.to_s), "")
      real = File.exist?(base) ? File.join(File.realpath(base), "") : base
      paths.all? do |path|
        expanded = File.expand_path(path.to_s)
        next false unless expanded.start_with?(base) && expanded.end_with?(".md")

        !File.exist?(expanded) || File.realpath(expanded).start_with?(real)
      end
    end

    def project_dir_within_root?(path, root)
      return true if path.nil?

      File.expand_path(path.to_s).start_with?(File.join(File.expand_path(root.to_s), ""))
    end

    def resolution_metadata?(entry)
      %i[requested_scope model_key fallback_model_key project_dir].all? do |key|
        entry.key?(key) || entry.key?(key.to_s)
      end
    end

    def resolve_memory(name, entry, system_dir:)
      return :stamped_paths unless project_dir_within_root?(field(entry, :project_dir), system_dir)

      Tools::MemoryRead.resolve(name, scope: field(entry, :requested_scope), model_key: field(entry, :model_key),
                                fallback_model_key: field(entry, :fallback_model_key),
                                project_dir: field(entry, :project_dir), system_dir: system_dir)
    end

    def resolved_memory_entry(resolved)
      { path: resolved.path, overlay: resolved.overlay_path && { path: resolved.overlay_path } }
    end

    def event(touch, conversation, view, cwd)
      run = touch.run
      name = run.call[:name].to_s
      sent = !touch.content || still_sent?(touch, conversation, view)
      dropped = touch.content && dropped?(touch, conversation)
      text = body_of(run.text)
      lines = diff = memory = nil
      case name
      when "read"
        lines = lines_of(run, cwd, text)
        text = text.sub(CLAMP_NOTE, "")
      when "edit", "write"
        diff = saved_diff(conversation[run.index], run.ref.run)
      when MEMORY_READ
        memory = memory_part(touch, conversation)
        if memory&.overlay
          overlay_key = Tools::MemoryRead.overlay_key(touch.key, memory.overlay_path)
          text = text.delete_suffix(overlay_tail(text, overlay_key)) if overlay_key
        end
      when MEMORY_WRITE
        text = run.call[:content].to_s
      end
      Event.new(tool_id: run.ref.id, derived: run.ref.derived?, index: run.index, step: run.step, op: OPS[name],
                sent: sent, dropped: dropped, forgotten: !sent && !dropped, lines: lines, diff: diff, text: text,
                memory: memory, shared_with: touch.content ? shared_with(touch, touch.key) : [])
    end

    # A run's output without its "[name]" lead.
    def body_of(text) = text.to_s.sub(ToolResponse::LEAD, "")

    # A read's Lines: its range off LLMContextStale.file_run, its last line
    # off +text+ (the lines it holds).
    def lines_of(run, cwd, text)
      file = LLMContextStale.file_run(run.index, run.ref, run.call, run.text, cwd || Dir.pwd, run.step)
      return Lines.new(first: nil, last: nil, whole: true, partial: true) unless file

      whole = file.lines == LLMContextStale::WHOLE
      return Lines.new(first: whole ? nil : file.lines.begin, last: nil, whole: whole, partial: true) if file.partial

      count = text.sub(CLAMP_NOTE, "").lines.size
      first = file.lines.begin
      last = first + [count, 1].max - 1
      last = [last, file.lines.end].min unless file.lines.end.infinite?
      Lines.new(first: first, last: last, whole: whole, partial: false)
    end

    # The diff saved for the run at +place+ of +entry+: ToolResponse.joined
    # saves an array (one per run, nil for none), .single the bare Hash.
    def saved_diff(entry, place)
      diffs = entry[:tool_diffs] || entry["tool_diffs"]
      diff = diffs.is_a?(Array) ? diffs[place] : diffs
      diff.is_a?(Hash) ? diff.transform_keys(&:to_sym) : nil
    end

    # The stamp's {name => entry} of a memory_read run, or nil.
    def memory_entries(run, conversation)
      stamp = stamp_hash(conversation[run.index], run.ref.run)
      entries = stamp && field(stamp, :memories)
      entries.is_a?(Hash) ? entries.transform_keys(&:to_s) : nil
    end

    def memory_part(touch, conversation)
      entries = memory_entries(touch.run, conversation)
      entry = entries && entries[touch.key]
      return nil unless entry.is_a?(Hash)

      path = field(entry, :path).to_s
      overlay = field(entry, :overlay)
      overlay_path = overlay.is_a?(Hash) ? field(overlay, :path).to_s : nil
      overlay_key = overlay_path && Tools::MemoryRead.overlay_key(touch.key, overlay_path)
      tail = touch.share == 1 && overlay_key ? overlay_tail(body_of(touch.run.text), overlay_key) : ""
      MemoryPart.new(scope: memory_scope(path), path: path, overlay_path: overlay_path,
                     overlay: tail.empty? ? nil : tail.sub(Tools::MemoryRead.overlay_prefix(overlay_key), ""))
    end

    # The overlay memory_read appended to +text+ (its separator and head
    # line included), or "".
    def overlay_tail(text, key) = Tools::MemoryRead.overlay_tail(text, key)

    # A memory's scope by where its file is: a project's under
    # memories/projects/<key>/, a system one's in memories/.
    def memory_scope(path) = File.basename(File.dirname(path, 2)) == "projects" ? "project" : "system"

    # What memory_read would answer now for +name+ (its entry and the overlay
    # read with it, as Tools::MemoryRead.call appends it); nil when a file is
    # gone.
    def memory_body(name, entry, read)
      body = read.call(field(entry, :path).to_s)
      overlay = field(entry, :overlay)
      return body unless overlay.is_a?(Hash)

      overlay_path = field(overlay, :path).to_s
      model_key = Tools::MemoryRead.overlay_key(name, overlay_path)
      model_key ? Tools::MemoryRead.append_overlay(body, read.call(overlay_path), model_key) : body
    rescue SystemCallError
      nil
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
    # index listing), less the ones its output says weren't found. Public:
    # `chi memory usage` counts reads the same way (MemoryUsage).
    def found_names(run)
      names = Tools::MemoryRead.parse_names(run.call[:content].to_s)
      last = run.text.split(ToolResponse::SEPARATOR).last.to_s
      missing = (match = MISSING.match(last)) ? match[1].split(",").map(&:strip) : []
      names - missing
    end

    def item(kind, key, group, conversation, view, stat, pinned, root)
      first = group.first
      contents = group.select(&:content)
      tokens = contents.sum { |touch| touch.sent.length / TokenUsage::CHARS_PER_TOKEN / touch.share }.ceil
      state = if contents.any? && contents.none? { |touch| still_sent?(touch, conversation, view) }
                contents.all? { |touch| dropped?(touch, conversation) } ? DROPPED : FORGOTTEN
              elsif kind == FILE && changed?(key, group.last.run, conversation, stat)
                STALE
              elsif kind == MEMORY && memory_changed?(key, group.last.run, conversation, stat, root)
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

      differs?(path, stamp, stat)
    end

    # Whether the memory +key+ has changed since +run+'s stamp (the item's
    # latest run): re-resolve stamps with request metadata, then compare the
    # answering files. Older path-only stamps compare their stamped files.
    # No stamp means not changed; a missing entry or overlay is changed.
    def memory_changed?(key, run, conversation, stat, root)
      stamp = stamp_hash(conversation[run.index], run.ref.run)
      return false unless stamp

      entries = field(stamp, :memories)
      entry = entries.is_a?(Hash) ? field(entries, key) : nil
      return false unless entry.is_a?(Hash)

      if resolution_metadata?(entry)
        resolved = resolve_memory(key, entry, system_dir: root)
        unless resolved == :stamped_paths
          return true unless resolved

          return true unless memory_paths?(resolved_memory_entry(resolved), root)

          stamped_overlay = field(entry, :overlay)
          stamped_overlay_path = stamped_overlay.is_a?(Hash) ? field(stamped_overlay, :path) : nil
          return true unless same_path?(resolved.path, field(entry, :path))
          return true unless same_path?(resolved.overlay_path, stamped_overlay_path)
        end
      end

      overlay = field(entry, :overlay)
      differs?(field(entry, :path), entry, stat) ||
        (overlay.is_a?(Hash) && differs?(field(overlay, :path), overlay, stat))
    end

    def same_path?(left, right)
      return left.nil? && right.nil? if left.nil? || right.nil?

      File.expand_path(left.to_s) == File.expand_path(right.to_s)
    end

    # Whether the file at +path+ is not what +entry+ ({mtime_ns:, size:}) says
    # it was, in mtime or size.
    def differs?(path, entry, stat)
      now = stat.call(path)
      mtime_ns = (now.mtime.to_i * 1_000_000_000) + now.mtime.nsec
      mtime_ns != field(entry, :mtime_ns) || now.size != field(entry, :size)
    rescue SystemCallError
      # Gone (or unreadable): not what the model saw.
      true
    end

    # +entry+'s tool_stamps at the run's place, whatever its shape (live has
    # symbol keys, a reloaded session string keys); nil when there is none.
    def stamp_hash(entry, place)
      stamps = entry[:tool_stamps]
      stamp = stamps.is_a?(Array) ? stamps[place] : nil
      stamp.is_a?(Hash) ? stamp : nil
    end

    # A file run's stamp: {path:, mtime_ns:, size:}. A memory_read's stamp
    # has no mtime_ns at its top ({memories: {name => ...}}), so a reader
    # that knows only file stamps - one from before memory stamps, any
    # strategy's - sees none there and never calls a memory stale.
    def stamp_of(entry, place)
      stamp = stamp_hash(entry, place)
      stamp && field(stamp, :mtime_ns) ? stamp : nil
    end

    def field(hash, key) = hash.key?(key) ? hash[key] : hash[key.to_s]

    private_class_method :all_touches, :touches, :failed?, :shared_with, :item, :still_sent?, :dropped?, :with_id,
                         :changed?, :memory_changed?, :same_path?, :differs?, :stamp_hash, :stamp_of, :field, :event, :body_of,
                         :lines_of, :saved_diff, :memory_entries, :memory_paths?, :project_dir_within_root?,
                         :resolution_metadata?, :resolve_memory, :resolved_memory_entry, :memory_part, :overlay_tail,
                         :memory_scope, :memory_body
  end
end
