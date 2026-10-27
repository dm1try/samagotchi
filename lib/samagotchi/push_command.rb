# frozen_string_literal: true

require "json"
require "time"
require_relative "cli/command"
require_relative "cli/exit"
require_relative "cli/flags"
require_relative "config"
require_relative "web/push"
require_relative "web/running"

module Samagotchi
  # `chi web push`: this machine's Web Push devices (Web::Push::Store),
  # without chi web running: list them, remove one, send a test push.
  # Never prints an endpoint or keys: a device is its short id and chi's
  # label. bin/chi branches here on `web push` before RunOptions (which
  # would refuse the word); `chi --remote X web push` is refused before
  # that (chi web runs on this machine only). See docs/cli.md.
  class PushCommand
    include CLI::Command

    USAGE = <<~TEXT
      Usage: chi web push <ls|rm|test> [options]
        ls [--format json]   the devices chi web pushes to: id, label, origin, added, last delivery,
                             last error, done turns; "stale" for another origin's (never sent to)
        rm ID                remove a device (it turns the bell on again to come back)
        test [ID]            a test push to ID, or to every device not stale (chi web need not run)
      A device is added by the bell in the phone's Home Screen app (docs/configuration.md, Phone notifications).
    TEXT

    SUBCOMMANDS = %w[ls rm test].freeze

    FLAGS = {
      "ls" => CLI::Flags.new(help: HELP_WORDS) { |f| f.value "--format" },
      "rm" => CLI::Flags.new(help: HELP_WORDS),
      "test" => CLI::Flags.new(help: HELP_WORDS)
    }.freeze

    # @param store [Web::Push::Store, nil] this machine's by default
    # @param origin [#call] → the public origin chi web runs on now (the
    #   running one's, else web.public_url's), nil when neither
    # @param client [#call, nil] (sub) → a Client for its origin; one
    #   signed with the store's key by default
    def initialize(argv, stdout: $stdout, stderr: $stderr, store: nil, origin: nil, client: nil)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
      @store = store || Web::Push::Store.new
      @origin = origin || -> { PushCommand.current_origin }
      @client = client
    end

    # The running chi web's https origin (a --tunnel's too), else
    # web.public_url's; nil when neither.
    def self.current_origin
      Web::Running.live_public_url&.origin || Web::PublicUrl.from_config(url: Config.get("web.public_url"))&.origin
    rescue Web::PublicUrl::Invalid
      nil
    end

    # @return [Integer] 0 done, 1 refused (a store others can read, a
    #   corrupt one, an unknown device, a failed test), 2 usage
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
    rescue Web::Push::Store::Insecure, Web::Push::Store::Corrupt, Web::Push::Refused => e
      error_line("#{command_name}: #{e.message}")
      CLI::Exit::FAILED
    end

    private

    def command_name = @sub && SUBCOMMANDS.include?(@sub) ? "chi web push #{@sub}" : "chi web push"
    def usage_on_error = nil

    def run_ls(options, args)
      return usage_error("ls takes no arguments") unless args.empty?

      format = options[:format]
      return usage_error("unknown format #{format.inspect}: use --format text|json") unless [nil, "text", "json"].include?(format)

      subs = devices
      origin = @origin.call
      if format == "json"
        @stdout.puts(JSON.generate(subs.map { |sub| sub.public_h.merge(stale: stale?(sub, origin)) }))
      elsif subs.empty?
        @stdout.puts("no devices (turn the bell on in the phone's Home Screen app)")
      else
        print_table(subs, origin)
      end
      0
    end

    def run_rm(_options, args)
      return usage_error("give one device ID (chi web push ls)") unless args.size == 1

      devices
      id = args.first
      gone = Web::Push::Store.short_id?(id) && @store.remove_device(id)
      return no_device(id) unless gone

      @stdout.puts("#{gone.id}  #{gone.label}  removed")
      0
    end

    def run_test(_options, args)
      return usage_error("give at most one device ID (chi web push ls)") if args.size > 1

      subs = devices
      if args.empty?
        origin = @origin.call
        subs = subs.reject { |sub| stale?(sub, origin) }
        if subs.empty?
          error_line("#{command_name}: no device to push to (chi web push ls)")
          return CLI::Exit::FAILED
        end
      else
        subs = subs.select { |sub| sub.id == args.first }
        return no_device(args.first) if subs.empty?
      end
      results = subs.map { |sub| test(sub) }
      results.all? ? 0 : CLI::Exit::FAILED
    end

    # One test push, its line printed; a :gone device is removed (as the
    # route does). @return [Boolean] delivered
    def test(sub)
      result = client_for(sub).deliver(sub, Web::Push::TEST_PAYLOAD, ttl: Web::Push::TEST_TTL, urgency: "high")
      words = [result.status, result.code, ("(#{result.ms} ms)" if result.ms)].reject { |part| part.to_s.empty? }.join(" ")
      words += ": #{result.error}" if result.error && !result.ok?
      if result.status == :gone
        @store.remove(sub.id)
        words += ": removed (the push service no longer knows it)"
      else
        @store.mark(sub.id, ok: result.ok?, error: result.ok? ? nil : (result.error || result.code))
      end
      @stdout.puts("#{sub.id}  #{sub.label}  #{words}")
      result.ok?
    end

    def client_for(sub)
      return @client.call(sub) if @client

      Web::Push::Client.new(key: Web::Push.load_key(@store), contact: Web::Push.contact(sub.origin))
    end

    # The store's devices, after its permission check.
    def devices
      @store.check_permissions!
      @store.subscriptions!
    end

    def no_device(id)
      error_line("#{command_name}: no device #{id[0, 16]} (chi web push ls)")
      CLI::Exit::FAILED
    end

    # Stale: made on another origin than chi web's now; none is when that
    # isn't known.
    def stale?(sub, origin) = !origin.nil? && sub.origin != origin

    def print_table(subs, origin)
      rows = subs.map do |sub|
        [sub.id, sub.label.to_s, sub.origin.to_s, when_text(sub.created_at), when_text(sub.last_ok_at) || "never",
         sub.done? ? "on" : "off", [stale?(sub, origin) ? "stale" : nil, sub.last_error].compact.join(", ")]
      end
      rows.unshift(["ID", "LABEL", "ORIGIN", "ADDED", "LAST OK", "DONE", "NOTE"])
      widths = rows.transpose.map { |column| column.map(&:length).max }
      rows.each { |row| @stdout.puts(row.zip(widths).map { |cell, width| cell.ljust(width) }.join("  ").rstrip) }
    end

    # An iso time as local "YYYY-MM-DD HH:MM"; nil for none.
    def when_text(iso)
      iso && Time.iso8601(iso).localtime.strftime("%Y-%m-%d %H:%M")
    rescue ArgumentError
      iso
    end
  end
end
