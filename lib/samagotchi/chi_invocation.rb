# frozen_string_literal: true

module Samagotchi
  # How the follow-up commands chi prints (ParentReport's chi answer and
  # chi send --wait, a stop's chi --resume) are spelled so that they work
  # when pasted: on this machine plain chi, against a remote (chi --remote
  # NAME, CHI_REMOTE=NAME alike) chi --remote NAME. What runs on this
  # machine only (--attach, --resume: remote attach is its own phase) has
  # no remote form: #attach and #resume are nil there, and #open_it and
  # #shows name the remote's chi web instead.
  # @!attribute remote [String, nil] the remote's name; nil: this machine
  ChiInvocation = Data.define(:remote) do
    def remote? = !remote.nil?

    # The command word: "chi", or "chi --remote NAME".
    def chi = remote? ? "chi --remote #{remote}" : "chi"

    # +words+ after #chi: command("answer ID …").
    def command(words) = "#{chi} #{words}"

    # chi --attach ID; nil remotely.
    def attach(id) = ("chi --attach #{id}" unless remote?)

    # chi --resume ID; nil remotely.
    def resume(id) = ("chi --resume #{id}" unless remote?)

    # What shows the session ("… shows it"): chi --attach ID, or the
    # remote's chi web.
    def shows(id) = attach(id) || web

    # Where the user opens it ("open it: …"): chi --attach ID or the web,
    # or the remote's chi web.
    def open_it(id) = remote? ? web : "#{attach(id)} or the web"

    # The remote's chi web, by name.
    def web = "chi web on #{remote}"
  end

  class ChiInvocation
    # This machine's: plain chi.
    HERE = new(remote: nil)
  end
end
