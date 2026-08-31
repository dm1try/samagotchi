# frozen_string_literal: true

require "pty"
require "stringio"

module Samagotchi
  # Reusable PTY harness for terminal-based testing.
  # Wraps PTY.spawn with winsize, exposes write/read_until/close!,
  # and handles ensure cleanup (kill process, close PTY descriptors).
  #
  # Usage:
  #   console = Samagotchi::PtyConsole.spawn(
  #     command: "echo hello",
  #     env: { "FOO" => "bar" },
  #     winsize: [24, 80]  # [rows, cols]
  #   )
  #   console.write("input\n")
  #   output = console.read_until(/pattern/, timeout: 5.0)
  #   console.close!
  class PtyConsole
    def self.spawn(command:, env: {}, winsize: [24, 80])
      master_io, slave_io, pid = PTY.spawn(env, command)
      console = new(master_io, slave_io, winsize)
      console.instance_variable_set(:@pid, pid)
      # Set winsize on the slave side (the one the child process sees)
      begin
        slave_io.ioctl(0x40045403, winsize.pack("S*")) if slave_io.respond_to?(:ioctl) && RUBY_PLATFORM =~ /darwin/
      rescue StandardError
        # ioctl may not work on all platforms — fall through
      end
      console
    end

    attr_reader :master_io, :slave_io, :winsize

    def initialize(master_io, slave_io, winsize)
      @master_io = master_io
      @slave_io = slave_io
      @winsize = winsize
      @pid = nil
      @closed = false
      @output = StringIO.new
      # Start reading background thread
      @reader = Thread.new { read_loop }
      @reader.abort_on_exception = false
    end

    def pid
      @pid
    end

    def write(input)
      raise "Already closed" if @closed
      @slave_io.puts(input)
      @slave_io.flush
    end

    # Read output until `pattern` matches, with `timeout` seconds max.
    # Returns the captured output string. Raises TimeoutError if not found.
    def read_until(pattern, timeout: 5.0)
      raise "Already closed" if @closed
      deadline = Time.now + timeout
      while Time.now < deadline
        line = @output.string
        if line =~ pattern
          return line
        end
        sleep(0.05)
      end
      raise TimeoutError, "Pattern #{pattern.inspect} not found within #{timeout}s. Got: #{@output.string.inspect}"
    end

    # Close the harness: send signal to child (if alive), close PTY descriptors.
    # Always runs cleanup even on error.
    def close!
      return if @closed
      @closed = true
      begin
        @reader.kill if @reader&.alive?
        @reader.join(1) if @reader&.alive?
      rescue StandardError
        # Ignore errors during cleanup
      end
      begin
        Process.kill("TERM", @pid) if @pid && Process.waitpid(@pid, Process::WNOHANG)
      rescue Errno::ESRCH, Errno::EPERM
        # Process already gone
      rescue StandardError
        # Ignore cleanup errors
      end
      @slave_io.close rescue nil
      @master_io.close rescue nil
    end

    private

    def read_loop
      begin
        until @closed
          data = @master_io.readpartial(4096) rescue nil
          @output << data if data
        end
      rescue EOFError
        # Normal termination
      rescue StandardError
        # Ignore read errors
      end
    end
  end

  class TimeoutError < StandardError; end
end