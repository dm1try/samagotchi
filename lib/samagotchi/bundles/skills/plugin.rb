# The skills bundle (docs/plugins.md, The skills bundle): a skill is a memory
# named skill_<name> that holds the steps of a task done with the user
# (docs/memory.md, Skills). The system bundle's identity already tells the
# model to save, follow and update skills; this bundle adds `/skill` for the
# user and keeps an eye on the model's rewrites.
#
# Settings (config.yml, bundles: skills:):
#   history_keep: 20   older versions kept per skill
#   nudge: true        steer the model once when a skill's step fails
require "date"

class Plugin
  USAGE = "usage: /skill save [name] [--system] | list | show <name> | diff <name> [N]"

  def initialize(settings = {})
    settings = {} unless settings.is_a?(Hash)
    @history_keep = positive(settings["history_keep"]) || 20
    @nudge = settings.key?("nudge") ? settings["nudge"] != false : true
  end

  def register(chi)
    chi.command "/skill", "skills (steps of a task we did): save [name] [--system], list, show <name>, diff <name> [N]",
                anytime: true do |args, ctx|
      command(args.to_s.strip, ctx)
    end
  end

  private

  # --- /skill ----------------------------------------------------------------

  def command(args, ctx)
    verb, rest = args.split(/\s+/, 2)
    rest = rest.to_s.strip
    case verb
    when "save" then save(rest, ctx)
    else USAGE
    end
  end

  # /skill save [name] [--system]: asks the model, in this session, to save
  # what was just done (the model has seen the commands; a side answer
  # wouldn't). The request runs as a turn; sent while a turn runs it joins
  # that turn at its next step, and the request says to finish the task
  # first. A REPL session (--no-shared) takes no messages: the request is
  # shown for the user to send.
  def save(rest, ctx)
    words = rest.split
    scope = words.delete("--system") ? "system" : "project"
    return USAGE if words.size > 1 || words.any? { |word| word.start_with?("-") }

    name = words.first && skill_name(words.first)
    return "/skill save: a name is letters, digits, _ and - (got #{words.first})" if words.first && !name

    request = save_request(name, scope, exists: name && skill_path(name))
    begin
      ctx.sessions.send(ctx.session_id, request)
    rescue Samagotchi::Plugin::Sessions::Error => e
      return "/skill save: #{e.message}. Send this yourself:\n\n#{request}"
    end
    what = name ? "skill #{name}" : "a skill"
    "asked chi to save #{what} (#{scope} scope); a running turn gets it at its next step"
  end

  def save_request(name, scope, exists:)
    target = name ? "skill `skill_#{name}`" : "a skill named `skill_<name>` (a short name for the task)"
    update = exists ? " It exists already: read it, keep what still holds, fix what changed, add a Changelog line." : ""
    <<~TEXT.strip
      Save what we just did as #{target} with memory_write, scope #{scope}.#{update} If you are still in the middle of the task, finish it first.
      Content: plain Markdown, no frontmatter:

      # Skill: #{name || "<name>"}

      ## Steps
      1. …
      ## Gotchas
      - …
      ## Changelog
      - #{Date.today.iso8601} created

      Steps are the commands and checks that worked, in order, with the real file and command names; a step that must pass says "stop if it fails". Dead ends and surprises go under Gotchas. Give memory_write a description: one line that starts with what this task is and names its main steps, in this task's own words, so the skill is found next time. Then show the skill briefly.
    TEXT
  end

  # --- skills on disk --------------------------------------------------------

  # "release", "skill_release", "Release-Notes" → "release", "release-notes";
  # nil for anything else.
  def skill_name(word)
    name = word.to_s.downcase.delete_suffix(".md").delete_prefix("skill_")
    name.match?(/\A[a-z0-9][a-z0-9_-]*\z/) ? name : nil
  end

  # The memories dir of each scope, as memory_read/memory_write resolve it.
  def memory_dirs
    %w[project system].to_h { |scope| [scope, File.expand_path(Samagotchi::Tools::MemoryRead.memories_dir(scope))] }
  end

  # The skill's file, project first (as memory_read looks), or nil.
  def skill_path(name, scope: nil)
    dirs = scope ? memory_dirs.slice(scope) : memory_dirs
    dirs.each_value do |dir|
      path = File.join(dir, "skill_#{name}.md")
      return path if File.file?(path)
    end
    nil
  end

  # --- helpers ---------------------------------------------------------------

  def positive(value)
    number = Integer(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
