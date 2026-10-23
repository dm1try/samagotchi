# frozen_string_literal: true

require "json"
require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "paths"
require_relative "remotes"
require_relative "session_access"
require_relative "session_access/http_transport"
require_relative "session_access/remote"

module Samagotchi
  # `chi remote`: the other machines whose sessions chi --remote NAME (or
  # CHI_REMOTE=NAME) reaches through their chi web (Remotes,
  # SessionAccess::Remote). add checks the address and the token with GET
  # /api/info before it saves anything; ls never prints a token.
  class RemoteCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi remote <add|ls|rm> [options]
        add NAME URL [--token-file FILE | --token-stdin]
              a machine's chi web (http://LAN-IP:PORT, as chi web prints it with web.host: lan;
              port 4567 by default), with its access token (chi web's LAN link carries it, after
              ?token=). It is checked first: the chi it runs, or why it can't be reached. Saved
              in #{Paths.tilde(Remotes.path)} (0600); an existing NAME is replaced.
        ls [--format json]    the remotes (never their tokens)
        rm NAME               forget one
      Then: chi --remote NAME send|answer|note|context|sessions|share|review …, or CHI_REMOTE=NAME.
    TEXT

    SUBCOMMANDS = %w[add ls rm].freeze

    FLAGS = {
      "add" => CLI::Flags.new(help: HELP_WORDS) do |f|
        f.value "--token-file"
        f.switch "--token-stdin"
      end,
      "ls" => CLI::Flags.new(help: HELP_WORDS) { |f| f.value "--format" },
      "rm" => CLI::Flags.new(help: HELP_WORDS)
    }.freeze

    # @param transport [#call, nil] (entry) → a transport for add's check;
    #   HTTPTransport by default
    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, path: Remotes.path, transport: nil)
      @argv = argv.dup
      @stdin = stdin
      @stdout = stdout
      @stderr = stderr
      @path = path
      @transport = transport || ->(entry) { SessionAccess::HTTPTransport.new(entry) }
    end

    # @return [Integer] exit status: 0 done, 1 refused or unreachable, 2 usage
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
    rescue Remotes::Invalid => e
      error_line("#{command_name}: #{e.message}")
      CLI::Exit::FAILED
    end

    private

    def command_name = @sub && SUBCOMMANDS.include?(@sub) ? "chi remote #{@sub}" : "chi remote"
    def usage_on_error = nil

    def run_add(options, args)
      return usage_error("give NAME and URL") unless args.size == 2
      return usage_error("--token-file and --token-stdin: choose one") if options[:token_file] && options[:token_stdin]

      name, url = args
      begin
        Remotes.check_name!(name)
        url = Remotes.normalize_url(url)
      rescue Remotes::Invalid => e
        return usage_error(e.message)
      end
      token = read_token(options)
      return CLI::Exit::FAILED if token == false

      entry = Remotes::Entry.new(name: name, url: url, token: token)
      found = check(entry) or return CLI::Exit::FAILED
      Remotes.put(entry, path: @path)
      @stdout.puts("#{name}  #{url}  chi #{found["version"]}, #{lan_words(found, entry)}")
      0
    end

    def run_ls(options, args)
      return usage_error("ls takes no arguments") unless args.empty?

      format = options[:format]
      return usage_error("unknown format #{format.inspect}: use --format text|json") unless [nil, "text", "json"].include?(format)

      entries = Remotes.all(path: @path)
      if format == "json"
        @stdout.puts(JSON.generate(entries.map { |e| { name: e.name, url: e.url, token: !e.token.nil? } }))
      elsif entries.empty?
        @stdout.puts("no remotes (chi remote add NAME URL --token-file FILE)")
      else
        width = entries.map { |e| e.name.length }.max
        entries.each { |e| @stdout.puts("#{e.name.ljust(width)}  #{e.url}#{"  (no token)" unless e.token}") }
      end
      0
    end

    def run_rm(_options, args)
      return usage_error("give one NAME") unless args.size == 1
      raise Remotes::NotFound, args.first unless Remotes.remove(args.first, path: @path)

      @stdout.puts("#{args.first}  removed")
      0
    end

    # The token from its file or stdin; nil for none (a loopback chi web
    # needs none), false after the error line.
    def read_token(options)
      text = if options[:token_file]
               begin
                 File.read(File.expand_path(options[:token_file]))
               rescue SystemCallError => e
                 error_line("#{command_name}: can't read #{options[:token_file]}: #{e.message.sub(/ @ .*/, "")}")
                 return false
               end
             elsif options[:token_stdin]
               read_stdin.to_s
             end
      return nil if text.nil?

      token = text.strip
      return token unless token.empty? || token.match?(/\s/)

      error_line("#{command_name}: #{options[:token_file] || "stdin"} holds no token (one line, chi web's web-token file)")
      false
    end

    # GET /api/info with the token: the answer, or nil after the line that
    # says why it can't be used.
    def check(entry)
      reply = @transport.call(entry).call(:get, "/api/info")
      problem = SessionAccess::Remote.info_problem(entry, reply)
      return fail_line(problem.message) if problem

      reply.json
    rescue SessionAccess::RemoteFailed => e
      fail_line("#{e.message}: start chi web on #{entry.host} with web.host: lan")
    end

    def lan_words(found, entry)
      return "loopback only" unless found["lan"]

      found["lan"] == entry.host ? "LAN #{found["lan"]}" : "LAN #{found["lan"]} (reached as #{entry.host})"
    end

    def fail_line(message)
      error_line("#{command_name}: #{message}")
      nil
    end
  end
end
