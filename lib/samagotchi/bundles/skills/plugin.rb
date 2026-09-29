# The skills bundle (docs/plugins.md, The skills bundle): a skill is a memory
# named skill_<name> that holds the steps of a task done with the user
# (docs/memory.md, Skills). The system bundle's identity already tells the
# model to save, follow and update skills; this bundle adds `/skill` for the
# user and keeps an eye on the model's rewrites.
#
# Settings (config.yml, bundles: skills:):
#   history_keep: 20   older versions kept per skill
#   nudge: true        steer the model once when a skill's step fails
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

  def command(_args, _ctx) = USAGE

  # --- helpers ---------------------------------------------------------------

  def positive(value)
    number = Integer(value.to_s, exception: false)
    number&.positive? ? number : nil
  end
end
