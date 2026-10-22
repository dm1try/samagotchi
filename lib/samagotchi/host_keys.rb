# frozen_string_literal: true

require "rbconfig"
require_relative "log"

module Samagotchi
  # Where a host's API key named VAR (its api_key_env:) comes from: the
  # environment variable when set, else, on macOS, the login Keychain's
  # generic password with service `chi` and account VAR (apps macOS starts,
  # like the Chi Helper, get a bare environment). SAMAGOTCHI_KEYCHAIN=off
  # skips the Keychain (specs set it, so nothing they start reads it).
  #
  # Keychain hits are cached for the process (every request authorizes,
  # and a `security` run costs ~0.1 s); misses are not, so a key added to
  # the Keychain works on the next try. A key is never logged, raised or
  # shown by inspect.
  module HostKeys
    SERVICE = "chi"
    OFF_ENV = "SAMAGOTCHI_KEYCHAIN"

    # Reads one generic password through /usr/bin/security (by absolute
    # path: the helper's PATH isn't the shell's) in its own process group,
    # killed at the deadline: a locked keychain or an access dialog must not
    # hang a turn. The deadline covers the spawn too (macOS can hold a first
    # exec for minutes while it scans the binary): the run is a thread the
    # caller gives up on, and a pid that turns up late is killed and reaped
    # there. nil on a miss, a non-zero exit, a timeout, no binary, or off
    # macOS.
    class Keychain
      SECURITY = "/usr/bin/security"
      TIMEOUT = 5

      # +spawner+: how the run starts (Process.spawn's arguments; specs stall it).
      def initialize(security: SECURITY, timeout: TIMEOUT, host_os: RbConfig::CONFIG["host_os"],
                     spawner: Process.method(:spawn))
        @security = security
        @timeout = timeout
        @macos = host_os.to_s.include?("darwin")
        @spawner = spawner
      end

      # @return [String, nil]
      def read(name)
        return nil unless @macos && File.executable?(@security)

        run(name)
      end

      def inspect = "#<#{self.class.name} #{@security}>"

      private

      def run(name)
        lock = Mutex.new
        pid = nil
        late = false
        worker = Thread.new do
          Thread.current.report_on_exception = false
          security(name) { |spawned| lock.synchronize { late ? stop(spawned) : pid = spawned } }
        end
        return worker.value if worker.join(@timeout)

        lock.synchronize do
          late = true
          stop(pid) if pid
        end
        Log.warn(:config, "keychain_timeout", name: name, seconds: @timeout)
        nil
      rescue SystemCallError
        nil
      end

      # One run, start to reap; yields the pid as soon as there is one.
      def security(name)
        reader, writer = IO.pipe
        pid = @spawner.call(@security, "find-generic-password", "-s", SERVICE, "-a", name, "-w",
                            in: File::NULL, out: writer, err: File::NULL, pgroup: true)
        writer.close
        yield pid
        key = reader.read.to_s.chomp
        _, status = Process.wait2(pid)
        status.success? && !key.strip.empty? ? key : nil
      ensure
        writer&.close unless writer&.closed?
        reader&.close
      end

      def stop(pid)
        Process.kill(:KILL, -pid)
      rescue SystemCallError
        nil
      end
    end

    # Never reads anything (specs).
    module NullKeychain
      def self.read(_name) = nil
    end

    @keychain = Keychain.new
    @cache = {}
    @mutex = Mutex.new

    class << self
      # @return [#read] where Keychain reads go (specs inject a fake)
      attr_reader :keychain

      def keychain=(reader)
        @mutex.synchronize do
          @keychain = reader
          @cache.clear
        end
      end

      # @return [String, nil] the key: the variable when set, else the Keychain's
      def fetch(name, env: ENV)
        from_env(name, env) || from_keychain(name, env: env)
      end

      # @return [Symbol, nil] :env, :keychain or nil (never the key)
      def source(name, env: ENV)
        return :env if from_env(name, env)

        from_keychain(name, env: env) ? :keychain : nil
      end

      # The Keychain's key for +name+ whatever the environment holds (chi
      # desktop status asks what the helper will get), nil when off.
      def from_keychain(name, env: ENV)
        return nil if off?(env)

        name = name.to_s
        cached = @mutex.synchronize { @cache[name] }
        return cached if cached

        key = keychain.read(name)
        @mutex.synchronize { @cache[name] = key } if key
        key
      end

      # SAMAGOTCHI_KEYCHAIN=off (any case).
      def off?(env = ENV) = env[OFF_ENV].to_s.strip.downcase == "off"

      # Whether this process reads the Keychain: macOS and not switched off
      # (the messages name the Keychain only then).
      def available?(host_os = RbConfig::CONFIG["host_os"], env: ENV) = host_os.to_s.include?("darwin") && !off?(env)

      # The command that stores the key for +name+ (prompting for it).
      def store_command(name) = "security add-generic-password -s #{SERVICE} -a #{name} -w"

      # Names only: the cache holds keys.
      def inspect = "#<#{name} cached=#{@mutex.synchronize { @cache.keys }.inspect}>"

      private

      def from_env(name, env)
        value = env[name.to_s].to_s
        value.strip.empty? ? nil : value
      end
    end
  end
end
