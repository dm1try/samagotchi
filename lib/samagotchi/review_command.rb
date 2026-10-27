# frozen_string_literal: true

require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "session"
require_relative "session_access"
require_relative "session_access/local"
require_relative "review_start"
require_relative "model_profile"

module Samagotchi
  # `chi review`: start a review session (the shared-sessions plan's §4, D2:
  # a review is its own session), for files or as a review fork of a working
  # session (--from: its recap, not its transcript; it keeps running), and
  # print how to invite someone (chi share). Local or through chi --remote
  # NAME (SessionAccess: the server checks the files against its own
  # project). See docs/sessions.md (Review sessions).
  class ReviewCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi review FILE… [--dir DIR] [--model NAME]
             chi review --from ID [FILE…] [--model NAME]
        FILE…         the files under review: each a file in the session's project (relative to
                      the session's folder), never a secret (.env, keys, credentials) nor chi's own
        --dir DIR     the session's folder (default: here; required with chi --remote)
        --model NAME  the model it runs on (default: the configured one; with --from, ID's)
        --from ID     a review of session ID: a new session that starts from ID's recap, not its
                      transcript; ID keeps running. FILE… is relative to ID's folder then.
      The review session starts idle; chi review prints how to invite someone (chi share). A
      participant's comments run as read-only review turns; you apply their proposals.
    TEXT

    FLAGS = CLI::Flags.new(help: HELP_WORDS) do |f|
      f.value "--dir"
      f.value "--model"
      f.value "--from"
    end

    # @param access [SessionAccess::Local, SessionAccess::Remote, nil]
    #   where the sessions are; default this machine's, in +state_dir+
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil, access: nil)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @access = access || SessionAccess::Local.new(state_dir: state_dir)
    end

    # @return [Integer] exit status: 0 started, 1 refused or failed, 2 usage
    def run
      if @argv.empty?
        @stdout.puts(USAGE)
        return 0
      end

      parsed = parse_flags(FLAGS, @argv)
      return parsed if parsed.is_a?(Integer)

      start(parsed.options, parsed.args)
    rescue ReviewStart::Refused, SessionAccess::BadRequest => e
      refused(e.message)
    rescue ModelProfile::MissingModel, Toolkit::Refused => e
      refused("could not start: #{e.message}")
    rescue ArgumentError => e
      refused(e.is_a?(Session::AmbiguousId) ? e.message : e.message.sub(/\ASession not found: /, "no session "))
    end

    private

    def command_name = "chi review"

    def start(options, files)
      from = options[:from]&.strip
      dir = options[:dir]
      return usage_error("give the files to review, or --from ID") if files.empty? && from.to_s.empty?
      return usage_error("--dir goes with files, not --from: a review of ID runs in ID's folder") if from && dir

      dir, error = folder(dir) unless from
      return error if error

      spec = SessionAccess::NewSession.new(prompt: nil, working_directory: dir, model_name: options[:model],
                                           review: SessionAccess::Review.new(subjects: files, from: from))
      created = @access.create(spec)
      print_started(created, files, from)
      0
    end

    # The session's folder: --dir, else here; a remote's must be its own
    # absolute path (no path of this machine is guessed there).
    # @return [Array(String, nil), Array(nil, Integer)]
    def folder(dir)
      if @access.remote?
        return [nil, usage_error("--dir DIR: the folder on #{@access.invocation.remote} (an absolute path there)")] if dir.to_s.strip.empty?
        return [nil, usage_error("--dir takes an absolute path on #{@access.invocation.remote}")] unless dir.start_with?("/")

        return [dir, nil]
      end
      dir = File.expand_path(dir || Dir.pwd)
      return [nil, usage_error("--dir #{dir}: no such folder")] unless File.directory?(dir)

      [dir, nil]
    end

    def print_started(created, files, from)
      id = created.id
      what = from ? "a review of #{from}" : "review"
      subjects = files.empty? ? "" : " · #{files.join(", ")}"
      @stdout.puts("#{id}  #{what}#{subjects} · idle")
      @stdout.puts("warning: #{created.model_warning}") if created.model_warning
      @stdout.puts("open it: #{@access.invocation.open_it(id[0, 8])}")
      # Behind a proxy that names the user, a link can be bound to them.
      identity = " --identity EMAIL" if @access.identity_header
      @stdout.puts("invite someone: #{@access.invocation.command("share #{id[0, 8]} --name NAME#{identity}")}")
    end

    def refused(message)
      error_line("#{command_name}: #{message}")
      CLI::Exit::FAILED
    end
  end
end
