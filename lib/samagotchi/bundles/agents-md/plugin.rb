# frozen_string_literal: true

# The agents-md bundle (docs/plugins.md, The agents-md bundle): a nested
# AGENTS.md of the session's checkout is steered into the conversation the
# first time a tool touches a file under its directory.
#
# chi's system prompt holds only the AGENTS.md chain from the checkout top
# down to the session's cwd (SystemPrompt#prompt_files), so an AGENTS.md in
# a directory the session doesn't run in (pkg/inner/AGENTS.md while the
# session runs in pkg/) is never seen. Working on a nested file usually
# means its directory's rules apply, so the first ok `read`, `write` or
# `edit` (settings tools) of such a file steers the nearest AGENTS.md into
# the running turn, at the loop's next boundary, as its own user message:
#
#   AGENTS.md for pkg/inner/ (applies to work under pkg/inner/):
#   <content>
#
# It is history, not system prompt: the prompt cache is untouched, and a
# resume, a woken worker or a fork (which copies the messages) never
# re-injects — a before_turn pass over event[:messages] replaces the loaded
# set with the dirs whose steer is already in the conversation. A steer
# that was queued but dropped (the model answered first) is not in the
# messages, so it fires again on the next touch. It never stops generation
# or thinking; a plugin steer can't cut (SteerCut#cut_for_steer).
#
# Paths are compared by File.realpath, falling back to File.expand_path for
# a path that doesn't exist: the session's cwd can be /tmp/x on macOS while
# git and the prompt's files give /private/tmp/x. The touched file's own git
# root must equal the session's checkout (ctx.repo_root): a file in another
# repository, a nested repository or a submodule is ignored, and the walk up
# stops at that root. Directories whose AGENTS.md is already in the system
# prompt (ctx.prompt_files: the chain and appended files) or already steered
# are skipped.
#
# Settings (config.yml, bundles: agents-md:):
#   tools: [read, write, edit]   the calls that count as a touch
#   max_chars: 16000            the content is cut at this many chars, the
#                               last line "[cut at N of M chars: read <path>
#                               for the rest]" naming the file by its absolute path
#
# skip_agents_md: true (top-level) disables the plugin, as it does the
# chain's loading.

require "samagotchi/config"
require "samagotchi/guardrails/context"

class Plugin
  FILE_NAME = "AGENTS.md"
  DEFAULT_TOOLS = %w[read write edit].freeze
  DEFAULT_MAX_CHARS = 16_000
  # The marker on the steer's first line (and what #rebuild matches):
  # <rel dir>/ is relative to the checkout top, so a dir is unique.
  MARKER = %r{\AAGENTS\.md for (.+)/ \(applies to work under \1/\):\n}

  def initialize(settings = {})
    tools = settings["tools"]
    @tools = if tools.nil?
               DEFAULT_TOOLS
             elsif tools.is_a?(Array)
               tools.map(&:to_s)
             else
               tools.to_s.split(/\s+/).reject(&:empty?)
             end
    chars = settings["max_chars"]
    chars = chars.to_i if chars
    @max_chars = chars.is_a?(Integer) && chars.positive? ? chars : DEFAULT_MAX_CHARS
    @git = Samagotchi::Guardrails::GitInfo.new
    # session_id => {rel dir => true}: the dirs steered this session.
    @loaded = Hash.new { |hash, id| hash[id] = {} }
    @lock = Mutex.new
  end

  def register(chi)
    # Replaces the loaded set from the conversation: a dropped steer fires
    # again on the next touch, a resume or a fork rebuilds from its messages.
    chi.on(:before_turn) { |event, ctx| rebuild(event, ctx) }
    chi.on(:after_tool_call) { |event, ctx| on_tool(event, ctx) }
  end

  # An ok touch of a file under a directory with a nested AGENTS.md steers
  # each candidate (the file's directory up to, not including, the checkout
  # top; outermost first) once per session.
  def on_tool(event, ctx)
    return if Samagotchi::Config.get("skip_agents_md") == true
    return unless @tools.include?(event[:tool].to_s)
    return unless event[:status].to_s == "ok"

    call = event[:call] || {}
    # The path a hook sees (docs/hooks.md): read on content:, write/edit on
    # path:, expanded against the session's cwd.
    raw = (event[:tool].to_s == "read" ? call[:content] : call[:path]).to_s.strip
    return if raw.empty?

    path = resolve(raw, base: ctx.cwd)
    top = resolve(ctx.repo_root)
    return if top.nil?

    # Scope: the file's own git root must be the session's checkout (a
    # nested repository, a submodule or another repository is ignored).
    file_root = resolve(@git.root(File.dirname(path)))
    return unless file_root && file_root == top

    prompt_files = Set.new(ctx.prompt_files.map { |file| resolve(file) })
    count = 0
    candidate_dirs(path, top).reverse_each do |dir|
      agents = File.join(dir, FILE_NAME)
      next unless File.file?(agents)
      next if prompt_files.include?(resolve(agents)) # in the system prompt already
      next if loaded(ctx).key?(relative_dir(dir, top))

      text = steer_text(dir, top, agents)
      next unless text

      # Queued: the dir is loaded; a steer dropped before it was injected
      # (the model answered first) is not queued, so it fires again later.
      count += 1 if ctx.steer(text) && (loaded(ctx)[relative_dir(dir, top)] = true)
    end
    ctx.log.info(:agents_md_steered, file: File.basename(path), n: count) if count.positive?
  end

  private

  # The dirs between +path+'s directory and +top+, file's directory first
  # (the caller reverses for outermost-first).
  def candidate_dirs(path, top)
    dirs = []
    dir = File.dirname(path)
    prefix = top.end_with?("/") ? top : "#{top}/"
    while dir != top && dir.start_with?(prefix)
      dirs << dir
      parent = File.dirname(dir)
      break if parent == dir

      dir = parent
    end
    dirs
  end

  # +dir+ relative to +top+ ("." for +top+ itself), or nil when it isn't under it.
  def relative_dir(dir, top)
    prefix = top.end_with?("/") ? top : "#{top}/"
    return "." if dir == top
    return nil unless dir.start_with?(prefix)

    dir.delete_prefix(prefix)
  end

  # The steer: the marker first line (what #rebuild matches), the content,
  # cut at max_chars with a pointer at the end. Nil when there is nothing to say.
  def steer_text(dir, top, agents)
    content = File.read(agents, encoding: "UTF-8")
    return nil if content.strip.empty?

    rel_dir = relative_dir(dir, top)
    header = "AGENTS.md for #{rel_dir}/ (applies to work under #{rel_dir}/):"
    return "#{header}\n#{content}" if content.length <= @max_chars

    body = content[0...@max_chars]
    "#{header}\n#{body}\n[cut at #{@max_chars} of #{content.length} chars: read #{agents} for the rest]"
  rescue SystemCallError, EncodingError
    nil
  end

  # Replaces the loaded set with the dirs whose steer the conversation
  # already carries (a user message, kind steer, source agents-md, the
  # marker on its first line).
  def rebuild(event, ctx)
    id = event[:session_id] || ctx.session_id
    found = {}
    Array(event[:messages]).each do |message|
      next unless message.is_a?(Hash)
      next unless (message[:role] || message["role"]).to_s == "user"
      next unless (message[:kind] || message["kind"]).to_s == "steer"
      next unless (message[:source] || message["source"]).to_s == "agents-md"

      if (match = MARKER.match((message[:content] || message["content"]).to_s))
        found[match[1]] = true
      end
    end
    @lock.synchronize { @loaded[id] = found }
  end

  # +path+ (relative ones against +base+) by File.realpath, falling back to
  # File.expand_path when it doesn't exist; nil for an empty one.
  def resolve(path, base: nil)
    path = path.to_s
    return nil if path.empty?

    path = File.expand_path(path, base) if base && !File.absolute_path?(path)
    File.realpath(path)
  rescue SystemCallError
    File.expand_path(path, base || Dir.pwd)
  end

  def loaded(ctx)
    @lock.synchronize { @loaded[ctx.session_id] }
  end
end
