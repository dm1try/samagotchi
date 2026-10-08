# frozen_string_literal: true

require "json"
require "time"
require "fileutils"

module LLMContextLive
  # The matrix root's cost ledger (ledger.jsonl: a line per finished run,
  # its cost as the server reported it) and its stop file (STOP: written on
  # a payment error, read before every run, removed only by hand). The cap
  # is checked before a run starts, so with --jobs N the total can pass it
  # by what the runs in flight spend.
  class Ledger
    def initialize(root)
      @path = File.join(root, "ledger.jsonl")
      @stop = File.join(root, "STOP")
      @mutex = Mutex.new
    end

    def total
      return 0.0 unless File.file?(@path)

      File.readlines(@path).sum { |line| JSON.parse(line)["cost"].to_f }
    rescue JSON::ParserError
      raise Error, "#{@path}: a line isn't JSON; fix it by hand"
    end

    def add(run_id, cost)
      @mutex.synchronize do
        File.open(@path, "a") { |file| file.puts(JSON.generate(run: run_id, cost: cost.to_f.round(4), at: Time.now.utc.iso8601)) }
      end
    end

    # Why no run may start: the stop file's reason, the cap reached, or nil.
    def blocked(cap)
      return "STOP: #{File.read(@stop).strip}" if File.exist?(@stop)
      return format("the cost cap: $%<total>.2f of $%<cap>.2f spent", total: total, cap: cap) if cap && total >= cap

      nil
    end

    def stop!(reason)
      File.write(@stop, "#{Time.now.utc.iso8601} #{reason}\n")
    end
  end
end
