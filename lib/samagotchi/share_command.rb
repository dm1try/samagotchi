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
      Usage: chi share ID --name NAME [--identity EMAIL] [--agent] [--expires 3d] [--cap 2]
             chi share ls [ID] [--format text|json]
             chi share cap ID PARTICIPANT DOLLARS
             chi share revoke ID [PARTICIPANT] | --all
        ID --name NAME   invite NAME to review session ID: prints the link they open (chi web on
                         the LAN, web.host: lan) and its QR code at a terminal. The link is shown
                         once; chi keeps only a digest of its token.
          --identity EMAIL  bind the link to that account: it opens only through chi web's auth proxy
                         signed in as EMAIL (web.public_url with web.proxy.identity_header, or
                         chi web --tunnel tailscale); a forwarded link opens for nobody else
          --agent        the participant is an agent (the same link, used as a Bearer token)
          --expires N    Nh or Nd, 1h to 30d (default 7d, web.participants.expires)
          --cap DOLLARS  what their turns may cost you, $0 to $1000 (default $2, web.participants.cap)
        ls [ID]          the participants of ID, or of every session (never a token)
        cap ID P D       set participant P's cap to D dollars, from their next turn
        revoke ID [P]    end participant P's link, or every link to ID; --all every session's
      Archiving or deleting a session revokes its links. You pay for a participant's turns:
      in a review session (chi review) they may only read; in a working session they act
      with its tools under your guardrails, and their asks come to you (once only).
    TEXT

    SUBCOMMANDS = %w[ls cap revoke].freeze

    # What the run changed, for the attached TUI's /share and /participants
    # revoke (whose worker announces the same change a few seconds later):
    # [[:joined, participant id]] for an invite, [[:left, id], …] for a
    # revoke; [] otherwise.
    attr_reader :changes

    # The invite's flags (chi share ID …), and ls's and revoke's.
    FLAGS = CLI::Flags.new(help: HELP_WORDS) do |f|
      f.value "--name"
      f.value "--identity"
      f.switch "--agent"
      f.value "--expires"
      f.value "--cap"
    end
    SUB_FLAGS = {
      "ls" => CLI::Flags.new(help: HELP_WORDS) { |f| f.value "--format" },
      "cap" => CLI::Flags.new(help: HELP_WORDS) { |_f| nil },
      "revoke" => CLI::Flags.new(help: HELP_WORDS) { |f| f.switch "--all" }
    }.freeze

    TIME_FORMAT = "%m-%d %H:%M"

    # @param access [SessionAccess::Local, SessionAccess::Remote, nil]
    #   where the sessions are; default this machine's, in +state_dir+
    # @param tty [Boolean, nil] print the QR code (default: stdout is a TTY)
    # @param name [String, nil] what its error lines are led by, when not
    #   "chi share …" (the attached TUI's /share and /participants)
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil, access: nil, tty: nil, name: nil)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @access = access || SessionAccess::Local.new(state_dir: state_dir)
      @tty = tty.nil? ? @stdout.respond_to?(:tty?) && @stdout.tty? : tty
      @name = name
      @changes = []
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
    rescue SessionAccess::BadRequest, Web::Grants::BadIdentity => e
      usage_error(e.message)
    rescue Web::Grants::Unwritable => e
      error_line("#{command_name}: #{e.message}")
      CLI::Exit::FAILED
    rescue ArgumentError => e
      error_line("#{command_name}: #{e.is_a?(Session::AmbiguousId) ? e.message : e.message.sub(/\ASession not found: /, "no session ")}")
      CLI::Exit::FAILED
    end

    private

    def command_name = @name || (@sub ? "chi share #{@sub}" : "chi share")
    def usage_on_error = nil

    def run_invite(options, args)
      return usage_error("give one session ID") unless args.size == 1
      return usage_error("--name NAME: who the link is for") if options[:name].to_s.strip.empty?

      ttl = Web::Grants.parse_ttl(options[:expires])
      return usage_error("--expires takes Nh or Nd, 1h to 30d (e.g. 3d)") if ttl == false

      cap = options[:cap] && dollars(options[:cap])
      return usage_error(CAP_USAGE) if cap == false

      identity = options[:identity] && Web::Grants.clean_identity(options[:identity])

      id = @access.resolve(args.first)
      invitation = @access.invite(id, name: options[:name], kind: options[:agent] ? "agent" : "human", ttl: ttl, cap: cap,
                                      identity: identity)
      print_invitation(id, invitation)
      warn_unbound(invitation.participant)
      @changes = [[:joined, invitation.participant.id]]
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

    CAP_USAGE = "a cap is dollars, $0 to $#{Web::Grants::MAX_CAP.to_i} (e.g. --cap 5)".freeze

    def run_cap(_options, args)
      return usage_error("give a session ID, a participant and dollars (chi share cap ID p_… 5)") unless args.size == 3

      participant = args[1]
      return usage_error("not a participant: #{participant} (chi share ls lists them)") unless Web::Grants::ID_RE.match?(participant)

      cap = dollars(args[2])
      return usage_error(CAP_USAGE) if cap == false

      id = @access.resolve(args.first)
      row = @access.set_participant_cap(id, participant: participant, cap: cap)
      @stdout.puts("#{row.id}  #{row.name}  cap #{money(row.cap)}")
      0
    end

    # A Float for "5", "2.50" or "$3" in the cap's range; false otherwise.
    def dollars(words)
      text = words.to_s.strip.delete_prefix("$")
      return false unless text.match?(/\A\d+(?:\.\d+)?\z/)

      value = text.to_f
      Web::Grants.cap?(value) ? value : false
    end

    def money(value) = value.nil? ? "-" : format("$%.2f", value)

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
      @changes = revoked.map { |row| [:left, row.id] }
      @stdout.puts("nothing to revoke") if revoked.empty?
      0
    end

    # Decision B: an unbound link behind a proxy that could bind it opens
    # for anyone the proxy lets in who holds it.
    def warn_unbound(row)
      return unless row.identity.nil? && (header = @access.identity_header)

      error_line("#{command_name}: warning: #{format(UNBOUND_WARNING, header: header)}")
    end

    UNBOUND_WARNING = "this link isn't bound to an account: anyone the proxy lets in who gets it can open it " \
                      "(--identity EMAIL binds it to the email %<header>s carries)"

    def print_invitation(id, invitation)
      row = invitation.participant
      @stdout.puts("#{row.id}  #{row.name} (#{row.kind}, #{row.role}) · session #{id[0, 8]} · expires " \
                   "#{local(row.expires_at, "%Y-%m-%d %H:%M")} · cap #{money(row.cap)}#{" · bound to #{row.identity}" if row.identity}")
      @stdout.puts(invitation.link)
      @stdout.puts("(shown once: chi keeps only its digest; chi share revoke #{id[0, 8]} #{row.id} ends it)")
      if invitation.warning
        error_line("#{command_name}: warning: #{invitation.warning} (#{@access.invocation.command("review --from #{id[0, 8]}")} starts one)")
      end
      unless invitation.lan
        @stdout.puts("chi web isn't on the LAN there (web.host: lan): this link opens on that machine only, as the participant")
      end
      @stdout.puts(Web::QR.lines(invitation.link)) if @tty
    end

    COLUMNS = ["SESSION", "PARTICIPANT", "NAME", "IDENTITY", "KIND", "ROLE", "CREATED", "EXPIRES", "LAST USED", "CAP",
               "STATE"].freeze

    def print_table(rows)
      cells = rows.map do |row|
        [row.session_id[0, 8], row.id, row.name, row.identity ? "#{row.identity} · bound" : "-", row.kind, row.role,
         local(row.created_at), local(row.expires_at), row.last_used_at ? local(row.last_used_at) : "-", money(row.cap),
         row.state]
      end
      widths = COLUMNS.each_index.map { |i| ([COLUMNS[i]] + cells.map { |c| c[i] }).map(&:length).max }
      [COLUMNS, *cells].each do |line|
        @stdout.puts(line.each_with_index.map { |cell, i| i == line.size - 1 ? cell : cell.ljust(widths[i]) }.join("  "))
      end
    end

    def local(stamp, format = TIME_FORMAT) = Time.iso8601(stamp.to_s).localtime.strftime(format)
  end
end
