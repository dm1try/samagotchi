# frozen_string_literal: true

require "fileutils"
require "monitor"
require_relative "../atomic_file"
require_relative "../paths"

module Samagotchi
  module Plugin
    # ctx.secrets (docs/plugins.md, Secrets): what a bundle keeps that must
    # not sit in a plain data file, tokens. Per bundle: bundle mcp's "linear"
    # and another bundle's "linear" are different secrets. A value is never
    # logged, never in an exception's message, never in #inspect.
    #
    # Core never caches: #get reads the store each time; a bundle keeps the
    # token in memory and reads again on a 401.
    #
    # The store is FileStore everywhere: one 0600 file per secret in a 0700
    # folder under the state dir. The login Keychain was tried and left out
    # (plan 3's B0, 2026-11-21): `security` takes a value without it showing
    # in an argument list only through `security -i` on stdin, whose line is
    # cut at about 4 KB and ends at a newline, and its prompt keeps 128
    # characters.
    class Secrets
      # The store can't be reached (disk, permissions). The message names
      # the store and the secret's name only.
      class Unavailable < StandardError; end

      # Another holder (another worker refreshing the same token) kept the
      # secret's lock past the deadline.
      class Busy < StandardError; end

      NAME = /\A[a-z0-9][a-z0-9._-]{0,63}\z/
      MAX_BYTES = 16 * 1024
      LOCK_TIMEOUT = 30

      # @param store [FileStore, MemoryStore] the bundle's own
      def initialize(store)
        @store = store
      end

      def inspect = "#<#{self.class.name} backend=#{backend}>"

      def pretty_print(printer) = printer.text(inspect)

      # @return [Symbol] :file (or :memory in the bundle test kit), for a
      #   bundle's status line
      def backend = @store.backend

      # @return [String, nil] the value, nil when there is none
      # @raise [ArgumentError] a bad name; [Unavailable]
      def get(name)
        @store.read(check_name(name))
      end

      # @return [true]
      # @raise [ArgumentError] a bad name or value; [Unavailable]; [Busy]
      def set(name, value, timeout: LOCK_TIMEOUT)
        name = check_name(name)
        value = check_value(value)
        @store.locked(name, timeout: timeout) { @store.write(name, value) }
        true
      end

      # @return [Boolean] whether there was one
      def delete(name, timeout: LOCK_TIMEOUT)
        name = check_name(name)
        @store.locked(name, timeout: timeout) { @store.remove(name) }
      end

      # Read, change, write under the secret's lock (two workers refreshing
      # the same token don't each spend the refresh token: the second one's
      # block gets the first one's new value). The block gets the value now
      # (nil for none) and returns the new one; nil deletes it.
      # @return [String, nil] what the secret holds after
      # @raise [ArgumentError] a bad name, or a block's bad value (nothing
      #   is written then); [Unavailable]; [Busy] past +timeout+ seconds
      def update(name, timeout: LOCK_TIMEOUT)
        raise ArgumentError, "ctx.secrets.update needs a block" unless block_given?

        name = check_name(name)
        @store.locked(name, timeout: timeout) do
          value = yield @store.read(name)
          if value.nil?
            @store.remove(name)
            next nil
          end

          @store.write(name, check_value(value))
          value
        end
      end

      private

      def check_name(name)
        name = name.to_s if name.is_a?(Symbol)
        raise ArgumentError, "a secret's name is a String like \"linear\" (#{NAME.source})" unless name.is_a?(String) && name.match?(NAME)

        name
      end

      # Never the value in the message.
      def check_value(value)
        raise ArgumentError, "a secret's value is a String (encode JSON yourself)" unless value.is_a?(String)
        raise ArgumentError, "a secret's value is at most #{MAX_BYTES} bytes" if value.bytesize > MAX_BYTES

        value
      end

      # One file per secret, <state dir>/plugins/<bundle>/secrets/<name>,
      # 0600 in a 0700 folder, written whole (AtomicFile). Its lock is
      # <name>.lock beside it, an exclusive flock held across processes.
      class FileStore
        POLL = 0.02

        # @param dir [String] the bundle's secrets folder
        # @param clock [#call] monotonic seconds (specs pass their own)
        # @param wait [#call] waits +seconds+ between lock tries
        def initialize(dir, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }, wait: ->(seconds) { sleep(seconds) })
          @dir = dir
          @clock = clock
          @wait = wait
        end

        # @param bundle [String]
        def self.for_bundle(bundle, env: ENV)
          new(File.join(Paths.state_dir(env: env), "plugins", bundle.to_s, "secrets"))
        end

        def backend = :file

        def inspect = "#<#{self.class.name}>"

        def read(name)
          File.binread(path(name)).force_encoding(Encoding::UTF_8)
        rescue Errno::ENOENT
          nil
        rescue SystemCallError, IOError
          raise Unavailable, "the secrets folder can't be read (secret #{name})"
        end

        def write(name, value)
          folder
          AtomicFile.write(path(name), value, perm: 0o600)
        rescue SystemCallError, IOError
          raise Unavailable, "the secrets folder can't be written (secret #{name})"
        end

        def remove(name)
          File.delete(path(name))
          true
        rescue Errno::ENOENT
          false
        rescue SystemCallError
          raise Unavailable, "the secrets folder can't be written (secret #{name})"
        end

        # @raise [Busy] the lock still held after +timeout+ seconds
        def locked(name, timeout:)
          lock = open_lock(name)
          begin
            take(lock, name, timeout)
            yield
          ensure
            lock.close
          end
        end

        private

        def path(name) = File.join(@dir, name)

        def folder
          FileUtils.mkdir_p(@dir, mode: 0o700)
          File.chmod(0o700, @dir)
        end

        def open_lock(name)
          folder
          File.open(File.join(@dir, "#{name}.lock"), File::RDWR | File::CREAT, 0o600)
        rescue SystemCallError, IOError
          raise Unavailable, "the secrets folder can't be locked (secret #{name})"
        end

        def take(lock, name, timeout)
          deadline = @clock.call + timeout
          until lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise Busy, "secret #{name} is held by another process (waited #{timeout} s)" if @clock.call >= deadline

            @wait.call(POLL)
          end
        end
      end

      # The bundle test kit's store: a Hash, never a disk or a Keychain.
      # bundle.secrets reads it, bundle.set(secrets: {...}) seeds it.
      class MemoryStore
        def initialize(values = {})
          @values = values
          @mutex = Monitor.new
        end

        def backend = :memory

        def inspect = "#<#{self.class.name}>"

        def to_h = @mutex.synchronize { @values.dup }

        # @param values [Hash] name => value, what the store then holds
        def replace(values)
          @mutex.synchronize { @values = values.to_h { |name, value| [name.to_s, value.to_s.dup.freeze] } }
        end

        def read(name) = @mutex.synchronize { @values[name]&.dup }

        def write(name, value)
          @mutex.synchronize { @values[name] = value.dup.freeze }
        end

        def remove(name) = @mutex.synchronize { !@values.delete(name).nil? }

        def locked(_name, timeout:, &) = @mutex.synchronize(&)
      end
    end
  end
end
