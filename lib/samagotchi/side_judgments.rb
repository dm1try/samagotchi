# frozen_string_literal: true

require_relative "llm/errors"
require_relative "log"
require_relative "system_one/log"

module Samagotchi
  # The Engine's System 1 side judgments: a question about the session
  # asked off the turn thread, whose answer is logged (and, for some
  # kinds, joined by the turn: ToolkitSuggest::Pending). One per kind is in
  # flight at a time; an ask that raises is one warn, never the turn's
  # failure; shutdown waits a short while for the asks still running.
  #
  # The caller prepares the ask's snapshot on its own thread: the block
  # sees only what it closes over.
  class SideJudgments
    def initialize
      @threads = {}
      @mutex = Mutex.new
    end

    # Whether +kind+'s last ask still runs.
    def in_flight?(kind)
      @mutex.synchronize { @threads[kind.to_sym]&.alive? || false }
    end

    # +kind+'s last ask's thread (specs join it), nil before the first.
    # @return [Thread, nil]
    def thread(kind) = @mutex.synchronize { @threads[kind.to_sym] }

    # Run the block on its own thread as +kind+'s ask. A cancelled request
    # (LLM::RequestCancelled) is no answer; any other StandardError goes
    # to +warn+ (error) and is no answer. +finish+ (result) is called on
    # the ask's thread whatever happened, with the block's value or nil.
    # @return [Thread, nil] nil (nothing started) while +kind+'s last ask
    #   still runs: the caller checks #in_flight? first to say so
    def start(kind, warn:, finish: nil, &block)
      @mutex.synchronize do
        return nil if @threads[kind.to_sym]&.alive?

        @threads[kind.to_sym] = Thread.new { run(warn, finish, &block) }
      end
    end

    # Wait for every running ask, up to +seconds+ in all.
    def join(seconds)
      threads = @mutex.synchronize { @threads.values }
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      threads.each do |thread|
        next if thread == Thread.current

        thread.join([deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max)
      end
      self
    end

    # A side judgment's append-only JSONL log (SystemOne::Log: 0600, one
    # line under an exclusive flock): a failed write is one warn under
    # +tag+ as +event+, never a raise.
    # @return [SystemOne::Log]
    def self.log(path, tag:, event:)
      SystemOne::Log.new(dir: File.dirname(path), file: File.basename(path),
                         warn: lambda { |reason|
                           Samagotchi::Log.warn(tag, event, echo: "[samagotchi:#{tag}] #{reason}")
                         })
    end

    private

    def run(warn, finish)
      result = nil
      begin
        result = yield
      rescue LLM::RequestCancelled
        result = nil
      rescue StandardError => e
        result = nil
        warn.call(e)
      ensure
        finish&.call(result)
      end
    end
  end
end
