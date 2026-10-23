# frozen_string_literal: true

module Samagotchi
  # How the follow-up commands chi prints (ParentReport's chi answer and
  # chi send --wait, a stop's chi --resume, the attached TUI's re-attach
  # lines) are spelled so that they work when pasted: on this machine plain
  # chi, against a remote (chi --remote NAME, CHI_REMOTE=NAME alike) chi
  # --remote NAME. A remote's chi web is named where the page is meant.
  # @!attribute remote [String, nil] the remote's name; nil: this machine
  ChiInvocation = Data.define(:remote) do
    def remote? = !remote.nil?

    # The command word: "chi", or "chi --remote NAME".
    def chi = remote? ? "chi --remote #{remote}" : "chi"

    # +words+ after #chi: command("answer ID …").
    def command(words) = "#{chi} #{words}"

    # chi --attach ID (chi --remote NAME --attach ID).
    def attach(id) = command("--attach #{id}")

    # chi --resume ID (chi --remote NAME --resume ID).
    def resume(id) = command("--resume #{id}")

    # What shows the session ("… shows it"): its attach.
    def shows(id) = attach(id)

    # Where the user opens it ("open it: …"): its attach, or the web (the
    # remote's chi web).
    def open_it(id) = "#{attach(id)} or #{remote? ? web : "the web"}"

    # The remote's chi web, by name.
    def web = "chi web on #{remote}"
  end

  class ChiInvocation
    # This machine's: plain chi.
    HERE = new(remote: nil)
  end
end
