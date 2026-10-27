# frozen_string_literal: true

require "json"
require_relative "cache_confirm"
require_relative "toolkit"

module Samagotchi
  # /toolkit, the session's toolkit (Session#toolkit): with no argument,
  # the tools its next turn declares with their estimated tokens, the
  # toolkit and the tools it leaves out (the ones find_tools reaches, the
  # ones it removes); `/toolkit NAME` puts the session
  # on another toolkit (its own adds and removes go), `/toolkit add TOOL`
  # and `/toolkit remove TOOL` change one tool. A change is saved at once
  # and applies at the next turn's start (Engine#apply_toolkit!). The
  # declared tools are the front of every request, so once the session has
  # a model reply a change asks first (CacheConfirm); --yes applies it.
  class ToolkitCommand
    NAME = "/toolkit"
    USAGE = "usage: #{NAME} [NAME | add TOOL | remove TOOL]".freeze
    # Characters per token for the estimates (context.chars_per_token's
    # default; a listing, not a meter).
    CHARS_PER_TOKEN = 4.0

    # @param engine [Engine] #session, #toolkit_explained, #toolkit_kits,
    #   #tools, #history?
    # @param save [#call] saves the session after a change
    def initialize(engine:, save:)
      @engine = engine
      @save = save
    end

    # @param args [String] what follows /toolkit (--yes anywhere)
    # @param confirm [Boolean] ask before a change once the session has a
    #   model reply (CacheConfirm); false applies it at once
    # @return [Array(String, Boolean, CacheConfirm::Confirm|nil)] the reply,
    #   whether the toolkit changed, and the confirm it asks for (nothing
    #   changed then)
    # @raise [ArgumentError] an unknown toolkit or tool, or bad words
    def run(args, confirm: true)
      words, yes = CacheConfirm.split(args, downcase: false)
      return [listing(@engine.toolkit_explained), false, nil] if words.empty?

      session = @engine.session or raise ArgumentError, "no session yet"
      before = @engine.toolkit_explained
      after = @engine.toolkit_explained(changed(before.toolkit, words.split))
      # Nothing the prompt carries changes (full +delegate on full): only
      # the origin is saved, so a no-op choice still counts as user-selected.
      if after.prompt_key == before.prompt_key
        if session.toolkit_origin != "chosen"
          session.toolkit_origin = "chosen"
          @save.call(session)
        end
        return [listing(before) + "\n(no change to what the next turn declares)", false, nil]
      end

      cost = Toolkit.cache_cost(before.prompt_key, after.prompt_key)
      if confirm && !yes && CacheConfirm.needed?(cost: cost, history: @engine.history?, changed: !cost.nil?)
        step = CacheConfirm.confirm(NAME, words)
        return [[change_line(before, after), reread_line(before, after), step.text].join("\n"), false, step]
      end

      session.toolkit = after.toolkit
      session.toolkit_origin = "chosen"
      @save.call(session)
      [[listing(after), "From the next turn's start (a running turn keeps its tools)."].join("\n"), true, nil]
    end

    # The toolkit, its declared tools with tokens, its kit's prompt text
    # (when it has one), and the ones left out: reachable with find_tools /
    # call_tool, removed (only /toolkit add brings one back), or, with
    # call_tool not declared, not loaded.
    def listing(explained)
      toolkit = explained.toolkit
      lines = ["toolkit: #{toolkit.label}#{" (applies at the next turn's start)" if explained.pending}"]
      if (fallback = explained.resolved.fallback)
        lines << "  #{fallback}: every tool is declared (full) until it resolves"
      end
      declared = explained.declared
      lines << "  declared (#{declared.size}, ~#{format_tokens(declared.sum { |entry| tokens(entry) })} tokens): " \
               "#{declared.map { |entry| "#{entry.name} ~#{format_tokens(tokens(entry))}" }.join(", ")}"
      lines << prompt_line(explained.resolved.prompt) if explained.resolved.prompt
      groups = explained.resolved.groups
      group_names = if groups == :all
                      "all"
                    elsif groups.empty?
                      "none"
                    else
                      groups.join(", ")
                    end
      lines << "  groups: #{group_names}"
      left_out = explained.left_out
      if explained.reachable.empty?
        lines << "  not loaded: #{left_out.empty? ? "none" : left_out.join(", ")}"
      else
        route = explained.removed.include?("find_tools") ? "call_tool" : "find_tools"
        lines << "  reachable (#{route}): #{explained.reachable.join(", ")}"
        lines << "  removed: #{explained.removed.empty? ? "none" : explained.removed.join(", ")}"
      end
      choices = @engine.toolkit_kits.map do |name, kit|
        source = kit.source.start_with?("memory:") ? " (#{kit.source})" : ""
        "#{name}#{source}"
      end
      lines << "  toolkits: #{choices.join(", ")}; #{USAGE.delete_prefix("usage: ")} changes it"
      lines.join("\n")
    end

    private

    # +toolkit+ after the words: NAME, add TOOL…, remove TOOL….
    def changed(toolkit, words)
      verb, *tools = words
      case verb.downcase
      when "add", "remove"
        raise ArgumentError, "#{NAME} #{verb} needs a tool name\n#{USAGE}" if tools.empty?

        tools.reduce(toolkit) do |kit, tool|
          raise ArgumentError, "no tool named #{tool} in this session" unless @engine.tools.key?(tool)

          verb.casecmp?("add") ? kit.adding(tool) : kit.removing(tool)
        end
      else
        raise ArgumentError, "#{NAME} takes one toolkit name\n#{USAGE}" unless tools.empty?

        kits = @engine.toolkit_kits
        raise ArgumentError, "no toolkit named #{verb} (toolkits: #{kits.keys.join(", ")})" unless kits.key?(verb)

        Toolkit.new(name: verb)
      end
    end

    def change_line(before, after)
      added = names(after) - names(before)
      removed = names(before) - names(after)
      parts = []
      # Removed (hard: call_tool can't reach it), declared before or not;
      # left out by the kit (soft); reachable now and not before.
      hard = after.removed - before.removed
      left = removed - hard
      soft = after.reachable - before.reachable - removed
      parts << "declares #{added.join(", ")}" unless added.empty?
      parts << "leaves out #{left.join(", ")}" unless left.empty?
      parts << "removes #{hard.join(", ")} (call_tool can't reach #{hard.size == 1 ? "it" : "them"})" unless hard.empty?
      parts << "lets call_tool reach #{soft.join(", ")}" unless soft.empty?
      # The kit's prompt text (Toolkit::Kit#prompt) is in the prompt too.
      text = after.resolved.prompt
      parts << (text ? "sends its kit's prompt text" : "drops the kit's prompt text") if text != before.resolved.prompt
      parts.concat(group_changes(before.resolved.groups, after.resolved.groups))
      parts << "declares the same tools under its own name" if parts.empty?
      "Switching to #{after.toolkit.label} #{parts.join("; ")}."
    end

    def group_changes(before, after)
      return [] if before == after
      return ["reaches all groups"] if after == :all
      return ["limits groups to #{after.empty? ? "none" : after.join(", ")}"] if before == :all

      added = after - before
      removed = before - after
      changes = []
      changes << "reaches groups #{added.join(", ")}" unless added.empty?
      changes << "leaves out groups #{removed.join(", ")}" unless removed.empty?
      changes
    end

    # What the confirm says is read again: from the tools on (the front of
    # every request), or from the kit's prompt text on when only that
    # changes (Explained#tools_key is unchanged: only a kit's prompt text).
    def reread_line(before, after)
      if before.tools_key == after.tools_key
        "The kit's prompt text is in the system prompt: the prompt is read again from it on."
      else
        "The tools are the front of every request: the whole prompt is read again from them on."
      end
    end

    def names(explained) = explained.declared.map(&:name)

    # The kit's prompt text (Toolkit::Kit#prompt): its first line, how many
    # more and its estimated tokens.
    def prompt_line(text)
      first, *rest = text.lines.map(&:chomp)
      more = rest.empty? ? "" : "+#{rest.size} line#{"s" if rest.size > 1}, "
      "  prompt: #{first} (#{more}~#{format_tokens((text.length / CHARS_PER_TOKEN).ceil)} tokens)"
    end

    # A tool's schema in tokens, estimated from its JSON.
    def tokens(entry) = (JSON.generate(entry.schema).length / CHARS_PER_TOKEN).round

    def format_tokens(count) = count >= 1000 ? format("%.1fk", count / 1000.0) : count.to_s
  end
end
