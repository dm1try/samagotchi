# frozen_string_literal: true

module Samagotchi
  module SessionAccess
    # Which session commands and flags run against another machine's
    # sessions (chi --remote NAME …, to come) and which run on this machine
    # only (refused under a remote, exit 2: "chi <cmd> runs on this machine
    # only: run it on <remote>"). The v1 scope is the remote-sessions plan's
    # D3: send, answer, note, a session's context (add, push, ls, show, rm)
    # and sessions list/stop/restart/archive/unarchive/delete; the rest
    # stays local. bin/chi's subcommands that act on the machine, not on
    # sessions, are MACHINE. The run flags (--attach, -p, --resume) are not
    # subcommands and not in this table (remote attach is its own phase).
    #
    # spec/session_access_contract_spec.rb fails when a subcommand, one of
    # its subcommands or one of a supported one's flags is in neither.
    module Contract
      SUPPORTED = :supported
      LOCAL_ONLY = :local_only

      # bin/chi subcommands that act on this machine: never sessions.
      MACHINE = %w[bootstrap update models desktop memory bundle].freeze

      # "command", "command sub" or either with a flag (its long name) →
      # SUPPORTED or LOCAL_ONLY. A LOCAL_ONLY command or subcommand lists
      # no flags: all of it is local.
      TABLE = {
        "send" => SUPPORTED,
        "send --message" => SUPPORTED,
        "send --new" => SUPPORTED,
        # Required with --new under a remote (D4: no laptop path guessed).
        "send --dir" => SUPPORTED,
        "send --continues" => SUPPORTED,
        "send --model" => SUPPORTED,
        "send --llm-context" => SUPPORTED,
        "send --llm-context-apply" => SUPPORTED,
        "send --llm-context-budget" => SUPPORTED,
        "send --thinking" => SUPPORTED,
        "send --toolkit" => SUPPORTED,
        "send --tool" => SUPPORTED,
        "send --no-tool" => SUPPORTED,
        "send --set" => SUPPORTED,
        "send --parent-answers" => SUPPORTED,
        "send --image" => SUPPORTED,
        "send --wait" => SUPPORTED,
        "send --cut" => SUPPORTED,
        "send --queue" => SUPPORTED,
        "send --timeout" => SUPPORTED,
        "send --format" => SUPPORTED,
        "send --turn" => SUPPORTED,
        # Refused on both (there is no --all).
        "send --all" => SUPPORTED,

        "answer" => SUPPORTED,
        "answer --question" => SUPPORTED,
        "answer --option" => SUPPORTED,
        "answer --text" => SUPPORTED,
        "answer --dismiss" => SUPPORTED,
        "answer --timeout" => SUPPORTED,
        "answer --format" => SUPPORTED,

        "note" => SUPPORTED,
        "note --message" => SUPPORTED,
        "note --source" => SUPPORTED,
        "note --all" => SUPPORTED,

        "context" => SUPPORTED,
        "context add" => SUPPORTED,
        "context add --cmd" => SUPPORTED,
        "context add --push" => SUPPORTED,
        "context add --every" => SUPPORTED,
        "context add --why" => SUPPORTED,
        "context add --hint" => SUPPORTED,
        "context add --project" => LOCAL_ONLY,
        "context push" => SUPPORTED,
        "context push --message" => SUPPORTED,
        "context push --project" => LOCAL_ONLY,
        "context ls" => SUPPORTED,
        "context ls --format" => SUPPORTED,
        "context ls --project" => LOCAL_ONLY,
        "context show" => SUPPORTED,
        "context show --json" => SUPPORTED,
        "context show --project" => LOCAL_ONLY,
        "context rm" => SUPPORTED,
        "context rm --project" => LOCAL_ONLY,
        "context refresh" => LOCAL_ONLY,
        "context mute" => LOCAL_ONLY,
        "context unmute" => LOCAL_ONLY,

        "sessions" => SUPPORTED,
        "sessions list" => SUPPORTED,
        "sessions list --sort" => SUPPORTED,
        "sessions list --order" => SUPPORTED,
        "sessions list --limit" => SUPPORTED,
        "sessions list --cwd" => SUPPORTED,
        "sessions list --format" => SUPPORTED,
        # Remotely every project's by default (D4); --scope=project needs
        # --cwd there.
        "sessions list --scope" => SUPPORTED,
        "sessions list --live" => SUPPORTED,
        "sessions list --archived" => SUPPORTED,
        "sessions stop" => SUPPORTED,
        "sessions restart" => SUPPORTED,
        "sessions archive" => SUPPORTED,
        "sessions unarchive" => SUPPORTED,
        "sessions delete" => SUPPORTED,
        "sessions delete --force" => SUPPORTED,
        "sessions prune" => LOCAL_ONLY,
        "sessions clean" => LOCAL_ONLY,
        "sessions stats" => LOCAL_ONLY,

        "broadcast" => LOCAL_ONLY
      }.freeze

      module_function

      # @param words [Array<String>] a command, maybe its subcommand, maybe
      #   a flag's long name: status("context", "add", "--cmd")
      # @return [Symbol, nil] SUPPORTED, LOCAL_ONLY, or nil when not listed
      def status(*words) = TABLE[words.join(" ")]

      # Whether +words+ run against a remote: the command, its subcommand
      # and the flag each listed SUPPORTED.
      def supported?(*words) = (1..words.size).all? { |n| status(*words.first(n)) == SUPPORTED }
    end
  end
end
