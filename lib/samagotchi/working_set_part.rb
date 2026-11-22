# frozen_string_literal: true

require_relative "context_note"
require_relative "prompt_part"
require_relative "text_diff"
require_relative "version"
require_relative "working_set_locator"
require_relative "working_set_own_changes"

module Samagotchi
  # One prompt part as chi sent it: what chi web's GET
  # /api/sessions/:id/working_set/part answers (WorkingSetRoutes), the
  # working set's "From the start" peek. The part is a slice of the head the
  # session already keeps (messages[0], ContextNote.system_head?), at the
  # place its build recorded (PromptPart#at, #len, #lead), when that head is
  # the one the parts were built with (PromptPart#head). Otherwise one line
  # says why, in the order below, the first that holds winning; under a
  # changed head a part chi can fetch again shows its source now (cases 4
  # and 5). See docs/internals/working-set.md (Prompt parts as sent).
  module WorkingSetPart
    # What the peek says instead of the sent text, one line per condition.
    WORDS = {
      older_worker: "This session's worker runs an older chi. Restart it to open prompt parts.",
      older_chi: "This session's prompt was built by an older chi. It shows here after the session's next turn.",
      no_prompt: "chi builds its prompt at the first turn.",
      running: "chi rebuilt its prompt. This is the source now; the sent text shows when the turn ends.",
      idle: "chi's prompt changed after it was sent. This is the source now; the sent text shows after the next turn."
    }.freeze

    # A part whose source changed since chi was sent it (#states).
    STALE = "stale"

    # The route's refusals.
    INVALID = "expected key (a prompt part's key)"
    UNKNOWN = "no such prompt part in this session"

    module_function

    # The answer for the part +key+ names (PromptPart.keys) among +parts+,
    # with +messages+ from the same source (a live worker's snapshot, else
    # the session file). +older_worker+: a live worker runs an older chi
    # than this one (#older_worker?); a worker of this chi (one restarted,
    # its parts still the file's until a turn builds them) gets the
    # older_chi words, which are true for it; +running+: a turn runs;
    # +root+: chi web's memories folder (MemoryPaths.system_dir); +cwd+: the
    # session's working directory (its AGENTS.md chain); +now+: with the
    # sent slice, the source now and its diff from what was sent
    # ({text, diff, gone}, the page's "now" tab), when a locator fetches it,
    # and +rebuild+: when chi's prompt gets the source now ("restart": a
    # +live+ worker keeps its prompt until it is next built; "next_turn":
    # a session with none builds it at its next turn). Never under a
    # changed head (cases 4 and 5 say when in their own words).
    # @return [Hash, nil] nil when no part has that key
    def answer(parts:, messages:, key:, older_worker:, running:, root:, cwd:, now: false, live: false)
      parts = PromptPart.list(parts)
      index = PromptPart.keys(parts).index(key.to_s)
      return nil unless index

      part = parts[index]
      shown = { part: part.to_h.slice(:kind, :label, :ref, :scope, :chars, :tokens) }
      tools = part.kind == "tools" && part.params.is_a?(Hash) ? part.params["tools"] : nil
      # Names and sizes, saved with the part: they open whatever the head.
      return shown.merge(tools: tools) if tools.is_a?(Array)

      if part.at.nil?
        reason = older_worker ? :older_worker : :older_chi
        return shown.merge(note: WORDS[reason], reason: reason.to_s)
      end

      head = Array(messages).first
      text = head.is_a?(Hash) && ContextNote.system_head?(head) ? (head[:content] || head["content"]) : nil
      return shown.merge(note: WORDS[:no_prompt], reason: "no_prompt") unless text.is_a?(String)

      if PromptPart.digest_of(text, 16) != part.head
        changed = running ? :running : :idle
        source = now_of(part, root: root, cwd: cwd)
        return shown.merge(note: WORDS[changed], reason: changed.to_s, changed: changed.to_s, now: source).compact
      end

      sent = sent_of(part, parts, text)
      source = now && now_of(part, root: root, cwd: cwd)
      return shown.merge(sent: sent) unless source

      # Each side ends its last line: a stripped note's or file's text would draw "\ No newline" markers otherwise.
      lined = ->(text) { text.end_with?("\n") ? text : "#{text}\n" }
      diff = source[:gone] ? nil : TextDiff.unified(lined.call(sent[:text]), lined.call(source[:text])).merge(new_file: false)
      shown.merge(sent: sent, now: source.merge(diff: diff), rebuild: live ? "restart" : "next_turn")
    end

    # The parts of +parts+ (a saved or wire list) whose source changed
    # since chi was sent it: [{key: PromptPart.keys', state: "stale"}],
    # only the stale ones. A part is stale when its locator
    # (WorkingSet::Locator, origin :prompt: the saved params, the guard)
    # fetches text whose PromptPart.digest_of differs from the part's saved
    # digest, or finds the source gone. Only what a locator fetches gets a
    # state (identity, preloads, notes, AGENTS.md): never an index (it
    # changes at every memory write, D5), an appended file, chi's own text
    # or a part an older chi built (no digest). A digest sees a part's text
    # only: a note newly applying, a new AGENTS.md in the chain, a memory
    # muted since change which parts exist, and say nothing here. +root+,
    # +cwd+: as #answer's.
    #
    # +messages+ (the same source's, top-level keys either way): a stale
    # part chi changed itself also gets +by_chi+ ({tool_id, step, op,
    # current}, #by_chi): current when the files it was read from hold
    # chi's own change, or what was sent, and one holds chi's (the row's
    # "edited"); not current when chi changed one and it changed again (or
    # the head the parts were built with is gone). The state stays "stale"
    # (an older page draws that). +running+: a turn runs, its own writes
    # not in +messages+ yet, so only a current by_chi goes out (a "changed
    # again" could be chi's own newest write).
    # @return [Array<Hash>]
    def states(parts, root:, cwd:, messages: nil, running: false)
      parts = PromptPart.list(parts)
      keys = PromptPart.keys(parts)
      own = nil
      parts.each_with_index.filter_map do |part, index|
        next unless part.digest && WorkingSet::Locator::FETCHED.include?(part.kind)

        composed = WorkingSet::Locator.of_part(part).composed(root: root, cwd: cwd)
        now = composed&.now
        next unless now
        next unless now.gone || PromptPart.digest_of(now.text) != part.digest

        state = { key: keys[index], state: STALE }
        next state unless messages

        messages = symbolized(messages) unless own
        own ||= WorkingSet::OwnChanges.of(messages, cwd: cwd)
        found = by_chi(part, parts, composed, own, messages)
        found && (found[:current] || !running) ? state.merge(by_chi: found) : state
      end
    end

    # The top-level keys of +messages+ as symbols (a live snapshot's are
    # strings; paired_runs reads symbols). Shared with chi web's builds.
    def symbolized(messages)
      Array(messages).map { |message| message.is_a?(Hash) ? message.transform_keys(&:to_sym) : message }
    end

    # Whether a worker that says it runs +version+ (its Bridge snapshot's
    # chi_version; nil: an older worker that doesn't say) is older than
    # this chi.
    def older_worker?(version)
      Gem::Version.new(version.to_s) < Gem::Version.new(VERSION)
    rescue ArgumentError
      true
    end

    # The part's slice of +head+: {text: its own text, lead: chi's line
    # before it}; base's leaves out the declarations when they sit in it.
    def sent_of(part, parts, head)
      slice = head[part.at, part.len].to_s
      lead = slice[0, part.lead.to_i].to_s
      body = slice[lead.length..].to_s
      tools = parts.first
      if part.kind == "base" && tools&.kind == "tools" && tools.at && tools.at >= part.at && tools.at < part.at + part.len
        from = tools.at - part.at - lead.length
        body = body[0, from].to_s + body[(from + tools.len.to_i)..].to_s
      end
      { text: body, lead: lead }
    end

    # The part's source now ({text:, gone:}), nil when there is none to
    # fetch or the guard refuses (WorkingSet::Locator, origin :prompt: a
    # memory with the saved params, an AGENTS.md on the session's own
    # chain, never an appended file).
    def now_of(part, root:, cwd:)
      now = WorkingSet::Locator.of_part(part).fetch(root: root, cwd: cwd)
      # The file's bytes as they are: JSON wants them valid (the saved head was scrubbed at save).
      now && { text: now.text && TextDiff.clean(now.text), gone: now.gone }
    end

    # A stale +part+'s own change ({tool_id, step, op, current}), or nil
    # (the plan's rule): each file the part was read from (+composed+'s,
    # the base and its overlay; a gone memory's base as sent) mapped to
    # chi's latest change of it (+own+). Current (the row's "edited") when
    # each file holds chi's change or what was sent (the sent slice split
    # at the overlay's prefix: a part is the base's text with its overlay
    # appended) and one holds chi's; else, when chi changed one, not
    # current. Without the head the parts were built with nothing proves
    # the other file unchanged: never current.
    def by_chi(part, parts, composed, own, messages)
      return nil if own.empty?

      dirs = memory_dirs(part)
      changes = composed.files.to_h do |file|
        change = own.for_file(file.path, role: file.role, key: file.key, dirs: dirs)
        [file, change && { change: change, current: own.current?(change, file.path) }]
      end
      latest = changes.values.compact.max_by { |found| found[:change].order }
      return nil unless latest
      # A file tool's change without a stamp can't say whether it still holds (an older session's): no word (L4).
      return nil if changes.values.compact.any? { |found| WorkingSet::OwnChanges::FILE_TOOLS.include?(found[:change].op) && !found[:change].stamp }

      sent = sent_text(part, parts, messages)
      current = changes.values.compact.select { |found| found[:current] }
      if sent && current.any? && unchanged_but_own?(composed, changes, sent, part)
        # An edit is current only when undoing chi's edits gives back what was sent (D2, stricter): else no word.
        return nil unless edits_undo?(composed, changes, sent, part, own)

        return current.max_by { |found| found[:change].order }[:change].to_h.merge(current: true)
      end

      latest[:change].to_h.merge(current: false)
    end

    # Whether every file of +composed+ holds chi's change or what was sent.
    def unchanged_but_own?(composed, changes, sent, part)
      return composed.files.all? { |file| changes[file]&.dig(:current) } if composed.now.gone

      sides = sides(composed, sent, part)
      composed.files.all? do |file|
        next true if changes[file]&.dig(:current)

        now_side, sent_side = sides[file.role]
        now_side == sent_side
      end && (composed.files.any? { |file| file.role == :overlay } || sides[:overlay][0] == sides[:overlay][1])
    end

    # Each current edit of a file of +composed+ undone back to its sent side
    # (OwnChanges.undoes_to?, over the file's edits and writes); true when
    # none is an edit.
    def edits_undo?(composed, changes, sent, part, own)
      edited = composed.files.select { |file| changes[file]&.dig(:current) && changes[file][:change].op == "edit" }
      return true if edited.empty?
      return false if composed.now.gone

      sides = sides(composed, sent, part)
      edited.all? do |file|
        now_side, sent_side = sides[file.role]
        written = own.memory_of_file(file.path, role: file.role, key: file.key, dirs: memory_dirs(part))
        written = nil unless written&.op == WorkingSet::OwnChanges::MEMORY_WRITE
        WorkingSet::OwnChanges.undoes_to?(now_side, sent_side, own.file_history(file.path), written: written)
      end
    end

    # The text now and the sent text split at the overlay's prefix:
    # {base: [now body, sent body], overlay: [now tail, sent tail]}.
    def sides(composed, sent, part)
      overlay = composed.files.find { |file| file.role == :overlay }
      now_body, now_tail = overlay ? split(composed.now.text, [overlay.key]) : [composed.now.text, ""]
      keys = [overlay&.key, *%i[model_key fallback_model_key].map { |key| param(part, key) }]
      sent_body, sent_tail = split(sent, keys)
      { base: [now_body, sent_body], overlay: [now_tail, sent_tail] }
    end

    # +text+ split at the overlay prefix of the first of +keys+ found:
    # [body, tail], the tail "" without one.
    def split(text, keys)
      keys.compact.uniq.each do |key|
        tail = Tools::MemoryRead.overlay_tail(text, key)
        return [text.delete_suffix(tail), tail] unless tail.empty?
      end
      [text, ""]
    end

    # The part's sent text when +messages+' head is the one the parts were
    # built with, else nil.
    def sent_text(part, parts, messages)
      head = Array(messages).first
      text = head.is_a?(Hash) && ContextNote.system_head?(head) ? (head[:content] || head["content"]) : nil
      return nil unless text.is_a?(String) && part.at && PromptPart.digest_of(text, 16) == part.head

      sent_of(part, parts, text)[:text]
    end

    # A memory part's saved folders by scope (none for an AGENTS.md).
    def memory_dirs(part)
      return {} unless WorkingSet::Locator::MEMORY_KINDS.include?(part.kind)

      { "project" => param(part, :project_dir), "system" => param(part, :system_dir) }
    end

    def param(part, key)
      part.params.is_a?(Hash) ? WorkingSet::MemoryGuard.field(part.params, key) : nil
    end

    private_class_method :sent_of, :now_of, :by_chi, :unchanged_but_own?, :edits_undo?, :sides, :split, :sent_text, :memory_dirs, :param
  end
end
