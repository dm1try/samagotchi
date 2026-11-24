# frozen_string_literal: true

require "json"
require_relative "peer_mailbox"
require_relative "peer_say"
require_relative "peer_roster"
require_relative "session"
require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "session_access/local"

module Samagotchi
  # `chi peer`: a peer agent's side of a session (PeerMailbox). The pair
  # scripts run pair; the peer's skill runs say for every message and quotes
  # the line it prints (what chi did with it, PeerSay); ls is what the owner
  # or the peer looks at. Through --remote the remote's chi web does the
  # same (SessionAccess::Remote).
  class PeerCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi peer <pair|unpair|say|ls> [options]
        pair NAME ID [--address ADDR] [--from TEXT]   pair peer NAME with session ID
              --address: where chi's sends go (none: it only answers); --from: who paired
        unpair NAME ID                                end the pairing (its messages stay)
        say NAME ID (--wake|--nowake) [--summary TEXT] [--re REF] [-m TEXT] [--wait SECONDS]
              a message from NAME (stdin without -m); prints what chi did with it.
              --wake: chi may run a turn for it; --re: the send it answers;
              --wait: how long to wait for chi's answer (0 to #{PeerSay::WAIT_MAX}, default 0)
        ls ID [--format json]                         the session's peers, their messages and receipts
      NAME: the peer (claude, codex): a lowercase letter, then lowercase letters and digits.
      ID: a session id or unique prefix. Find ids with: chi sessions list [--live]
    TEXT

    SUBCOMMANDS = %w[pair unpair say ls].freeze

    FLAGS = {
      "pair" => CLI::Flags.new(help: HELP_WORDS) do |f|
        f.value "--address"
        f.value "--from"
      end,
      "unpair" => CLI::Flags.new(help: HELP_WORDS),
      "say" => CLI::Flags.new(help: HELP_WORDS) do |f|
        f.switch "--wake"
        f.switch "--nowake", key: :wake, set: false
        f.value "--summary"
        f.value "--re"
        f.value "-m", "--message", key: :text
        f.value "--wait"
      end,
      "ls" => CLI::Flags.new(help: HELP_WORDS) { |f| f.value "--format" }
    }.freeze

    # @param argv [Array<String>] the arguments after "peer"
    # @param access [SessionAccess::Local, SessionAccess::Remote, nil] where
    #   the sessions are; default this machine's, in +state_dir+
    # @param sleeper [#call, nil] a say's wait between two looks (specs)
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, state_dir: nil, access: nil, sleeper: nil)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @state_dir = state_dir || Session.default_state_dir
      @access = access || SessionAccess::Local.new(state_dir: @state_dir)
      @sleeper = sleeper
    end

    # @return [Integer] exit status: 0 done, 1 refused or failed, 2 usage
    def run
      @sub = @argv[0]
      if @sub.nil? || HELP_WORDS.include?(@sub)
        @stdout.puts(USAGE)
        return 0
      end
      return usage_error("unknown subcommand #{@sub}") unless SUBCOMMANDS.include?(@sub)

      parsed = parse_flags(FLAGS.fetch(@sub), @argv[1..])
      return parsed if parsed.is_a?(Integer)

      send(:"run_#{@sub}", parsed.options, parsed.args)
    rescue PeerMailbox::Invalid => e
      error_line("#{command_name}: #{e.message}")
      CLI::Exit::FAILED
    rescue ArgumentError, SessionAccess::RemoteFailed => e
      error_line("#{command_name}: #{e.message}")
      CLI::Exit::FAILED
    end

    private

    def command_name = @sub && SUBCOMMANDS.include?(@sub) ? "chi peer #{@sub}" : "chi peer"

    # NAME and ID, checked: [name, id], or the exit status.
    def name_and_id(args)
      return usage_error("give the peer's NAME and the session ID") unless args.size == 2

      name, given = args
      return usage_error(PeerMailbox.name_problem(name)) unless PeerMailbox.valid_name?(name)

      [name, @access.resolve_id(given)]
    end

    def run_pair(options, args)
      checked = name_and_id(args)
      return checked if checked.is_a?(Integer)

      name, id = checked
      paired = @access.peer_pair(id, name, address: options[:address], from: options[:from])
      unless paired.status == :paired
        error_line("#{command_name}: #{paired.refusal}")
        return CLI::Exit::FAILED
      end

      @stdout.puts("#{id[0, 8]}  paired with #{PeerMailbox.label(name)}")
      0
    end

    def run_unpair(_options, args)
      checked = name_and_id(args)
      return checked if checked.is_a?(Integer)

      name, id = checked
      unless @access.peer_unpair(id, name)
        error_line("#{command_name}: #{id[0, 8]} isn't paired with #{name}")
        return CLI::Exit::FAILED
      end

      @stdout.puts("#{id[0, 8]}  unpaired from #{PeerMailbox.label(name)} (its messages stay)")
      0
    end

    def run_say(options, args)
      return usage_error("give --wake or --nowake") unless options.key?(:wake)

      wait = wait_seconds(options[:wait]) or return CLI::Exit::USAGE

      checked = name_and_id(args)
      return checked if checked.is_a?(Integer)

      name, id = checked
      text = utf8(options[:text] || read_stdin)
      return usage_error("no text: pass -m TEXT or pipe it in") if text.nil? || text.strip.empty?

      said = @access.peer_say(id, name, text: text, summary: options[:summary], wake: options[:wake], re: options[:re],
                                        wait: wait, **(@sleeper ? { sleeper: @sleeper } : {}))
      unless said.received?
        error_line("#{command_name}: #{said.line(name)}")
        return CLI::Exit::FAILED
      end

      @stdout.puts(said.line(name))
      said.receipt&.state == "refused" ? CLI::Exit::FAILED : 0
    end

    # --wait's seconds (0 without it); nil after its usage error.
    def wait_seconds(value)
      return 0 if value.nil?

      seconds = Float(value, exception: false)
      return seconds if seconds&.between?(0, PeerSay::WAIT_MAX)

      usage_error("--wait takes seconds from 0 to #{PeerSay::WAIT_MAX}, not #{value.inspect}")
      nil
    end

    def run_ls(options, args)
      refused = format_refusal(options[:format])
      return refused if refused
      return usage_error("give the session ID") unless args.size == 1

      id = @access.resolve_id(args.first)
      peers = @access.peer_list(id)
      if options[:format] == "json"
        @stdout.puts(JSON.pretty_generate(peers.map(&:to_h)))
      elsif peers.empty?
        @stdout.puts("no peers")
      else
        peers.each { |peer| print_peer(peer) }
      end
      0
    end

    def print_peer(peer)
      paired = peer.paired? ? "paired #{peer.paired_at}#{" by #{peer.from}" if peer.from}" : "not paired"
      @stdout.puts("#{peer.name}  #{paired}#{"  sends to #{peer.address}" if peer.address}")
      peer.messages.each do |row|
        @stdout.puts("  ##{row.serial} #{PeerRoster.state_words(row.receipt)}  #{row.summary}".rstrip)
      end
    end
  end
end
