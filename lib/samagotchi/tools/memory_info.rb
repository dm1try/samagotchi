# frozen_string_literal: true

module Samagotchi
  module Tools
    # Reports current Ruby process memory (RSS) and GC statistics.
    # Useful for the model to understand its runtime constraints.
    class MemoryInfo
      NAME        = "memory_info"
      DESCRIPTION = "Show current Ruby process RSS memory and GC statistics."

      def self.name        = NAME
      def self.description = DESCRIPTION

      def self.call(_content = nil)
        [
          "RSS: #{rss_mb} MB",
          "heap_live_slots: #{GC.stat[:heap_live_slots]}",
          "gc_count: #{GC.stat[:minor_gc_count] + GC.stat[:major_gc_count]}"
        ].join("\n")
      end

      def self.rss_mb
        if File.exist?("/proc/self/status")
          line = File.readlines("/proc/self/status").find { |l| l.start_with?("VmRSS:") }
          line ? (line.split[1].to_i / 1024.0).round(1) : "N/A"
        else
          `ps -o rss= -p #{Process.pid}`.strip.to_i / 1024.0
        end
      rescue StandardError
        "N/A"
      end
    end
  end
end
