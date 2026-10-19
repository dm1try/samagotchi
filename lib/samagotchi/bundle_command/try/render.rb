# frozen_string_literal: true

require "json"

module Samagotchi
  class BundleCommand
    module Try
      # What `chi bundle try` prints of a run: the trace's text lines (on
      # stdout, or on stderr under the --json report) and --keep's paths.
      class Render
        def initialize(stdout:, stderr:)
          @stdout = stdout
          @stderr = stderr
        end

        # The child's stderr (without its Session: line), then the trace.
        def trace(trace, json:, child_stderr:)
          error_lines = child_stderr.lines.reject { |line| line.start_with?("Session: ") }
          @stderr.write(error_lines.join)
          if json
            lines(trace, @stderr, include_answer: false)
            @stdout.puts JSON.generate(trace.to_h.transform_keys(&:to_s))
          else
            lines(trace, @stdout, include_answer: true)
          end
        end

        def sandbox(sandbox)
          @stderr.puts "sandbox: #{sandbox.root}"
          @stderr.puts "debug log: #{File.join(sandbox.state_home, "samagotchi", "samagotchi.log")}"
        end

        def lines(trace, output, include_answer:)
          output.puts "tools:"
          trace.tools.each do |tool|
            output.puts format("  %d %-16s %-7s %dms  %s", tool[:index], tool[:name], tool[:status],
                               tool[:duration_ms], JSON.generate(tool[:args].to_s[0, 60]))
          end
          trace.notices.each { |notice| output.puts "notices: [#{notice["hook"] || "hook"}] #{notice["text"]}" }
          trace.cards.each do |card|
            output.puts "card: #{[card["title"], card["body"]].compact.join(" — ")}"
          end
          trace.questions.each do |entry|
            question = entry.dig("pending_question", "question").to_s
            outcome = if entry["cancelled"] && entry["reason"] == "non_interactive"
                        "unanswerable (non_interactive)"
                      elsif entry["cancelled"]
                        "cancelled (#{entry["reason"]})"
                      elsif entry["answer"]
                        "answered"
                      else
                        "unanswered"
                      end
            output.puts "questions: #{JSON.generate(question)} -> #{outcome}"
          end
          if trace.interactive_blocked
            count = trace.denied.size + trace.questions.count { |question| question["cancelled"] && question["reason"] == "non_interactive" }
            output.puts "warn: #{count} question(s)/call(s) couldn't be answered"
          end
          if include_answer
            answer_lines = trace.answer.lines
            output.puts "answer:"
            answer_lines.first(10).each { |line| output.puts "  #{line.chomp}" }
            output.puts "  … (truncated)" if answer_lines.size > 10
          end
          tokens = trace.tokens
          prompt = tokens[:prompt] || "unknown"
          completion = tokens[:completion] || "unknown"
          cost = if trace.cost
                   "#{"~" if trace.cost_is_estimate}$#{format("%.4f", trace.cost)}"
                 else
                   "unknown"
                 end
          output.puts "tokens: #{prompt} in / #{completion} out  cost #{cost}  exit #{trace.exit_code}" \
                      "#{"  (#{trace.session_id})" if trace.session_id}"
        end
      end
    end
  end
end
