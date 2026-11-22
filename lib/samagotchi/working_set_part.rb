# frozen_string_literal: true

require_relative "context_note"
require_relative "prompt_files"
require_relative "prompt_part"
require_relative "version"
require_relative "working_set"

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

    # The route's refusals.
    INVALID = "expected key (a prompt part's key)"
    UNKNOWN = "no such prompt part in this session"

    # The memory kinds a changed head re-fetches (with the saved params).
    MEMORY_KINDS = %w[identity preloads notes].freeze

    module_function

    # The answer for the part +key+ names (PromptPart.keys) among +parts+,
    # with +messages+ from the same source (a live worker's snapshot, else
    # the session file). +older_worker+: a live worker runs an older chi
    # than this one (#older_worker?); a worker of this chi (one restarted,
    # its parts still the file's until a turn builds them) gets the
    # older_chi words, which are true for it; +running+: a turn runs;
    # +root+: chi web's memories folder (MemoryPaths.system_dir); +cwd+: the
    # session's working directory (its AGENTS.md chain).
    # @return [Hash, nil] nil when no part has that key
    def answer(parts:, messages:, key:, older_worker:, running:, root:, cwd:)
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
        now = now_of(part, root: root, cwd: cwd)
        return shown.merge(note: WORDS[changed], reason: changed.to_s, changed: changed.to_s, now: now).compact
      end

      shown.merge(sent: sent_of(part, parts, text))
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
    # fetch or the guard refuses: a memory with the saved params
    # (WorkingSet.prompt_memory_now), an AGENTS.md on the session's own
    # chain. An appended file is never fetched (its path came with a run's
    # flags, not from where the session works); base, the kit, a plugin's
    # section, an index and the session lines are chi's own text.
    def now_of(part, root:, cwd:)
      now = if MEMORY_KINDS.include?(part.kind)
              WorkingSet.prompt_memory_now(part.kind, part.ref, part.params, root: root)
            elsif part.kind == "agents"
              agents_now(part, cwd)
            end
      now && { text: now.text, gone: now.gone }
    end

    def agents_now(part, cwd)
      path = part.params.is_a?(Hash) ? part.params["path"].to_s : ""
      return nil if path.empty? || cwd.to_s.empty?

      chain = PromptFiles.agents_paths(cwd).map { |candidate| real(candidate) }
      return nil unless chain.include?(real(path))

      text = PromptFiles.content(path)
      WorkingSet::Now.new(text: text, diff: nil, gone: text.nil?)
    end

    # The same file however it's spelled (/tmp vs /private/tmp on macOS).
    def real(path)
      File.realpath(path)
    rescue SystemCallError
      File.expand_path(path)
    end

    private_class_method :sent_of, :now_of, :agents_now, :real
  end
end
