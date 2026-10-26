# frozen_string_literal: true

require "json"
require "rbconfig"
require_relative "fake_executables"

# A fake `tailscale` for Web::Tunnel::Tailscale (FakeExecutables): it answers
# `status --json`, `serve status --json` and `lock status --json` from the
# JSON files in its dir (trimmed fixtures from spec/fixtures/tailscale, with
# example names), logs every argv to argv.log, and as the real one does,
# `serve --bg --https=443 TARGET` sets 443 to that one handler and
# `serve --https=443 off` drops 443, other ports kept. Point
# SAMAGOTCHI_TAILSCALE_CLI at #path (a spec never reaches the real one:
# spec_helper points it at a missing file).
#
#   fake = FakeTailscale.new(dir, serve: "serve-443-on.json")
#   fake.fail!("serve-bg", "consent needed")   # status, serve-status, lock, serve-bg, serve-off
#   fake.slow!("serve-bg", 0.5)                # answers (and applies) 0.5 s later
#   fake.argv  # => ["status --json", "serve status --json", ...]
class FakeTailscale
  FIXTURES = File.expand_path("../fixtures/tailscale", __dir__)
  NAME = "chi-host.example-tailnet.ts.net"

  BODY = <<~'SH'
    dir="$(dirname "$0")/state"
    printf '%s\n' "$*" >> "$dir/argv.log"
    case "$*" in
      "status --json") key=status ;;
      "serve status --json") key=serve-status ;;
      "lock status --json") key=lock ;;
      "serve --bg --https=443 "*) key=serve-bg ;;
      "serve --https=443 off") key=serve-off ;;
      *) echo "fake tailscale: unknown command: $*" >&2; exit 2 ;;
    esac
    if [ -f "$dir/fail-$key" ]; then cat "$dir/fail-$key" >&2; exit 1; fi
    if [ -f "$dir/slow-$key" ]; then sleep "$(cat "$dir/slow-$key")"; fi
    if [ -f "$dir/hang-$key" ]; then
      cat "$dir/hang-$key"
      : > "$dir/printed-$key"
      exec sleep 30
    fi
    case "$key" in
      status) cat "$dir/status.json" ;;
      serve-status) cat "$dir/serve.json" ;;
      lock) cat "$dir/lock.json" ;;
      *) exec "$(cat "$dir/ruby")" --disable-gems "$dir/serve.rb" "$@" ;;
    esac
  SH

  SERVE_RB = <<~'RUBY'
    require "json"
    dir = __dir__
    path = File.join(dir, "serve.json")
    serve = JSON.parse(File.read(path))
    name = JSON.parse(File.read(File.join(dir, "status.json")))["Self"]["DNSName"].delete_suffix(".")
    if ARGV[1] == "--bg"
      target = ARGV[3]
      (serve["TCP"] ||= {})["443"] = { "HTTPS" => true }
      (serve["Web"] ||= {})["#{name}:443"] = { "Handlers" => { "/" => { "Proxy" => target } } }
      puts "Available within your tailnet:", "", "https://#{name}/", "|-- proxy #{target}", "",
           "Serve started and running in the background.", "To disable the proxy, run: tailscale serve --https=443 off"
    else
      serve["TCP"]&.delete("443")
      serve["Web"]&.delete_if { |key, _| key.end_with?(":443") }
      %w[TCP Web].each { |key| serve.delete(key) if serve[key] && serve[key].empty? }
    end
    File.write(path, JSON.generate(serve))
  RUBY

  attr_reader :dir, :path

  def initialize(dir, status: "status.json", serve: "serve-off.json", lock: "lock.json")
    @dir = dir
    @state = File.join(dir, "state")
    FileUtils.mkdir_p(@state)
    @path = FakeExecutables.fake_executable(dir, "tailscale", BODY)
    File.write(File.join(@state, "ruby"), RbConfig.ruby)
    File.write(File.join(@state, "serve.rb"), SERVE_RB)
    File.write(File.join(@state, "argv.log"), "")
    self.status = status
    self.serve = serve
    self.lock = lock
  end

  # A fixture name, or a Hash written as JSON.
  def status=(value)
    write("status.json", value)
  end

  def serve=(value)
    write("serve.json", value)
  end

  def lock=(value)
    write("lock.json", value)
  end

  def status = JSON.parse(File.read(File.join(@state, "status.json")))
  def serve = JSON.parse(File.read(File.join(@state, "serve.json")))

  # +key+ (status, serve-status, lock, serve-bg, serve-off) exits 1 with +text+ on stderr.
  def fail!(key, text = "boom") = File.write(File.join(@state, "fail-#{key}"), text)

  # +key+ prints +text+ and sleeps 30 s.
  def hang!(key, text = "") = File.write(File.join(@state, "hang-#{key}"), text)

  def printed?(key) = File.exist?(File.join(@state, "printed-#{key}"))

  # +key+ waits +seconds+ before it answers (and, for serve-bg/serve-off,
  # changes 443), as a slow tailscaled would.
  def slow!(key, seconds) = File.write(File.join(@state, "slow-#{key}"), seconds.to_s)

  # Every command it ran, one argv per line.
  def argv = File.read(File.join(@state, "argv.log")).lines(chomp: true)

  def self.fixture(name) = JSON.parse(File.read(File.join(FIXTURES, name)))

  private

  def write(file, value)
    text = value.is_a?(String) ? File.read(File.join(FIXTURES, value)) : JSON.generate(value)
    File.write(File.join(@state, file), text)
  end
end
