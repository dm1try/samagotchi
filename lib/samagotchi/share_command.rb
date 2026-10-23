# frozen_string_literal: true

require "json"
require "time"
require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "session"
require_relative "session_access"
require_relative "session_access/local"
require_relative "web/grants"
require_relative "web/qr"

module Samagotchi
  # `chi share`: invite a participant to review a session (the
  # shared-sessions plan: a Web::Grants grant, one session, one person or
  # agent, 7 days unless --expires says otherwise), list the participants,
  # revoke them. Local or through chi --remote NAME (SessionAccess). The
  # token is printed once, in the link; chi keeps only its digest. See
  # docs/internals/participants.md.
  class ShareCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi share ID --name NAME [--agent] [--expires 3d]
             chi share ls [ID] [--format text|json]
             chi share revoke ID [PARTICIPANT] | --all
        ID --name NAME   invite NAME to review session ID: prints the link they open (chi web on
                         the LAN, web.host: lan) and its QR code at a terminal. The link is shown
                         once; chi keeps only a digest of its token.
          --agent        the participant is an agent (the same link, used as a Bearer token)
          --expires N    Nh or Nd, 1h to 30d (default 7d)
        ls [ID]          the participants of ID, or of every session (never a token)
        revoke ID [P]    end participant P's link, or every link to ID; --all every session's
      Archiving or deleting a session revokes its links. A participant sees the session's title
      and status; comments come in a later chi.
    TEXT

    SUBCOMMANDS = %w[ls revoke].freeze

    # The invite's flags (chi share ID …), and ls's and revoke's.
    FLAGS = CLI::Flags.new(help: HELP_WORDS) do |f|
      f.value "--name"
      f.switch "--agent"
      f.value "--expires"
    end
    SUB_FLAGS = {
      "ls" => CLI::Flags.new(help: HELP_WORDS) { |f| f.value "--format" },
      "revoke" => CLI::Flags.new(help: HELP_WORDS) { |f| f.switch "--all" }
    }.freeze

    EXPIRES_RE = /\A(\d+)([hd])\z/
    TIME_FORMAT = "%m-%d %H:%M"

    # @param access [SessionAccess::Local, SessionAccess::Remote, nil]
    #   where the sessions are; default this machine's, in +state_dir+
    # @param tty [Boolean, nil] print the QR code (default: stdout is a TTY)
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil, access: nil, tty: nil)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @access = access || SessionAccess::Local.new(state_dir: state_dir)
      @tty = tty.nil? ? @stdout.respond_to?(:tty?) && @stdout.tty? : tty
    end

    # @return [Integer] exit status: 0 done, 1 refused or failed, 2 usage
    def run
      first = @argv[0]
      if first.nil? || HELP_WORDS.include?(first)
        @stdout.puts(USAGE)
        return 0
      end

      @sub = SUBCOMMANDS.include?(first) ? first : nil
      parsed = parse_flags(@sub ? SUB_FLAGS.fetch(@sub) : FLAGS, @sub ? @argv[1..] : @argv)
      return parsed if parsed.is_a?(Integer)

      send(:"run_#{@sub || "invite"}", parsed.options, parsed.args)
    rescue SessionAccess::BadRequest => e
      usage_error(e.message)
    rescue ArgumentError => e
      error_line("#{command_name}: #{e.is_a?(Session::AmbiguousId) ? e.message : e.message.sub(/\ASession not found: /, "no session ")}")
      CLI::Exit::FAILED
    end

    private

    def command_name = @sub ? "chi share #{@sub}" : "chi share"
    def usage_on_error = nil

    def run_invite(options, args)
      return usage_error("give one session ID") unless args.size == 1
      return usage_error("--name NAME: who the link is for") if options[:name].to_s.strip.empty?

      ttl = expires(options[:expires])
      return usage_error("--expires takes Nh or Nd, 1h to 30d (e.g. 3d)") if ttl == false

      id = @access.resolve(args.first)
      invitation = @access.invite(id, name: options[:name], kind: options[:agent] ? "agent" : "human", ttl: ttl)
      print_invitation(id, invitation)
      0
    end

    def run_ls(options, args)
      return usage_error("ls takes at most one session ID") if args.size > 1

      format = options[:format]
      return usage_error("unknown format #{format.inspect}: use --format text|json") unless [nil, "text", "json"].include?(format)

      id = args.first && @access.resolve(args.first)
      rows = @access.participants(id)
      if format == "json"
        @stdout.puts(JSON.generate(rows.map(&:to_h)))
      elsif rows.empty?
        @stdout.puts(id ? "no participants in #{id[0, 8]} (chi share #{id[0, 8]} --name NAME invites one)" : "no participants")
      else
        print_table(rows)
      end
      0
    end

    def run_revoke(options, args)
      if options[:all]
        return usage_error("--all takes no session ID") unless args.empty?
      elsif !args.size.between?(1, 2)
        return usage_error("give a session ID (and a participant), or --all")
      end
      participant = args[1]
      return usage_error("not a participant: #{participant} (chi share ls lists them)") if participant && !Web::Grants::ID_RE.match?(participant)

      id = args.first && @access.resolve(args.first)
      revoked = @access.revoke_participants(id, participant: participant)
      revoked.each { |row| @stdout.puts("#{row.id}  #{row.name}  revoked") }
      @stdout.puts("nothing to revoke") if revoked.empty?
      0
    end

    # Seconds, nil for the default, false for words that aren't Nh/Nd.
    def expires(words)
      return nil if words.nil?

      match = EXPIRES_RE.match(words.to_s.strip) or return false
      seconds = match[1].to_i * (match[2] == "h" ? 3600 : Web::Grants::DAY)
      seconds.between?(3600, Web::Grants::MAX_TTL) ? seconds : false
    end

    def print_invitation(id, invitation)
      row = invitation.participant
      @stdout.puts("#{row.id}  #{row.name} (#{row.kind}, #{row.role}) · session #{id[0, 8]} · expires #{local(row.expires_at, "%Y-%m-%d %H:%M")}")
      @stdout.puts(invitation.link)
      @stdout.puts("(shown once: chi keeps only its digest; chi share revoke #{id[0, 8]} #{row.id} ends it)")
      unless invitation.lan
        @stdout.puts("chi web isn't on the LAN there (web.host: lan): this link opens on that machine only")
      end
      @stdout.puts(Web::QR.lines(invitation.link)) if @tty
    end

    COLUMNS = ["SESSION", "PARTICIPANT", "NAME", "KIND", "ROLE", "CREATED", "EXPIRES", "LAST USED", "STATE"].freeze

    def print_table(rows)
      cells = rows.map do |row|
        [row.session_id[0, 8], row.id, row.name, row.kind, row.role, local(row.created_at), local(row.expires_at),
         row.last_used_at ? local(row.last_used_at) : "-", row.state]
      end
      widths = COLUMNS.each_index.map { |i| ([COLUMNS[i]] + cells.map { |c| c[i] }).map(&:length).max }
      [COLUMNS, *cells].each do |line|
        @stdout.puts(line.each_with_index.map { |cell, i| i == line.size - 1 ? cell : cell.ljust(widths[i]) }.join("  "))
      end
    end

    def local(stamp, format = TIME_FORMAT) = Time.iso8601(stamp.to_s).localtime.strftime(format)
  end
end
