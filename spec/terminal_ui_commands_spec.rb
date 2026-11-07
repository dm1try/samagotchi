# frozen_string_literal: true

require "samagotchi/terminal_ui"
require "spec_helper"
require "stringio"
require "json"
require_relative "support/recording_surface"

RSpec.describe Samagotchi::TerminalUI do
  let(:client) { instance_double(Samagotchi::Client) }
  let(:agent) { described_class.new(client: client) }

  around { |example| with_env("SAMAGOTCHI_DEFAULT_MODEL" => "Gemma-4B-it") { example.run } }

  describe "stats REPL commands" do
    it "renders the session metrics summary via format_session_metrics" do
      metrics = agent.engine.metrics
      metrics.call(type: :turn_started, session_id: "s", prompt: "x")
      metrics.call(type: :generation_started)
      metrics.call(type: :generation_chunk, payload: { "timings" => { "prompt_n" => 10, "predicted_n" => 5 } })
      metrics.call(type: :generation_completed)
      metrics.call(type: :turn_completed, result: double(respond_to?: false))

      output = Samagotchi::TerminalUI::Formatting.format_session_metrics(metrics.snapshot)
      expect(output).to include("turns:")
      expect(output).to include("tokens in/out:")
      expect(output).to include("10/5")
    end

    it "returns the same /stats text for the CLI through the module-level method (no private send)" do
      metrics = agent.engine.metrics
      metrics.call(type: :turn_started, session_id: "s", prompt: "x")
      metrics.call(type: :generation_started)
      metrics.call(type: :generation_chunk, payload: { "timings" => { "prompt_n" => 10, "predicted_n" => 5 } })
      metrics.call(type: :generation_completed)
      metrics.call(type: :turn_completed, result: double(respond_to?: false))

      module_output = Samagotchi::TerminalUI::Formatting.format_session_metrics(metrics.snapshot)
      instance_output = Samagotchi::TerminalUI::Formatting.format_session_metrics(metrics.snapshot)
      expect(module_output).to eq(instance_output)
      expect(module_output).to include("turns:")
      expect(module_output).to include("tokens in/out:")
      expect(module_output).to include("10/5")
    end

    it "lists the calls made under an alias's name under by tool, only when there are any" do
      base = agent.engine.metrics.snapshot.merge(tool_calls_total: 3, tool_calls_by_tool: { "execute" => 3 })
      lines = Samagotchi::TerminalUI::Formatting.format_session_metrics(base.merge(tool_calls_aliased: { "bash" => 2 })).lines.map(&:chomp)
      by_tool = lines.index("  by tool:        execute=3")
      expect(lines[by_tool + 1]).to eq("  called as:      bash=2")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics(base)).not_to include("called as")
    end

    # After /model the snapshot's model_segments split the sums per model
    # (SessionMetrics::ModelSegment); one model keeps the tokens line.
    describe "the models: block" do
      around { |example| with_env("TZ" => "UTC") { example.run } }

      def row(ref, from, to, turns, prompt, completion, **extra)
        { model_ref: ref, started_at: "2026-10-17T#{from}:00.000Z", ended_at: to && "2026-10-17T#{to}:00.000Z",
          turns: turns, prompt_sum: prompt, completion_sum: completion, cached_sum: 0, cost_sum: 0,
          cost_estimate_sum: 0, avg_decode_tps: nil, last_decode_tps: nil, tps_source: nil, prefill_tokens: 0,
          prefill_cost_estimate: nil, **extra }
      end

      def stats(segments, tokens = {}, snapshot = {})
        base = agent.engine.metrics.snapshot
        totals = { prompt_sum: 278_000, completion_sum: 30_000, source: "server" }.merge(tokens)
        Samagotchi::TerminalUI::Formatting.format_session_metrics(base.merge(turns: 20, tokens: base[:tokens].merge(totals), model_segments: segments)
                                                .merge(snapshot)).lines.map(&:chomp)
      end

      let(:two) do
        [row("deepseek:v4.1-flash", "10:02", "10:41", 14, 182_000, 21_000, cost_sum: 0.041, avg_decode_tps: 52.0,
                                                                         tps_source: "server", last_decode_tps: 50.0),
         row("splash:qwen3-35b", "10:43", nil, 6, 96_000, 9_000, cost_estimate_sum: 0.018, avg_decode_tps: 38.2,
                                                                 tps_source: "server", last_decode_tps: 38.0,
                                                                 prefill_tokens: 58_000, prefill_cost_estimate: 0.012)]
      end

      it "replaces the tokens line with a row per model, the switch's prefill and the total" do
        output = stats(two, { last_decode_tps: 38.0, tps_source: "server", avg_decode_tps: 47.0, cost_sum: 0.041,
                              cost_estimate_sum: 0.018 }, { price_host: "splash" })

        expect(output.join("\n")).not_to include("tokens in/out")
        models = output.index { |line| line.start_with?("models:") }
        expect(output[models, 4]).to eq([
          "models:           deepseek:v4.1-flash  10:02–10:41  14 turns  182.0k in / 21.0k out  52 tok/s  $0.04",
          "                  splash:qwen3-35b     10:43–now    6 turns   96.0k in / 9.0k out  38 tok/s  ~$0.02",
          "                    └ switch prefill 58.0k uncached prompt ≈$0.01",
          "                  total                             20 turns  278.0k in / 30.0k out (all requests, server-reported)"
        ])
        expect(output).to include("speed:            38 tok/s out (last, server, splash:qwen3-35b), avg 47 tok/s",
                                  "cost:             $0.04 reported + ~$0.02 from each model's host prices (this session only)")
      end

      it "keeps one model's output byte-identical (no rows, or one)" do
        plain = stats([])
        expect(stats([two.first])).to eq(plain)
        expect(plain).to include("tokens in/out:    278000/30000 (all requests, server-reported)")
      end

      it "names a legacy session's turns with no ref \"earlier turns\" and the folded rows \"N earlier segments\"" do
        legacy = row(nil, "09:00", "09:30", 3, 1000, 100)
        folded = row(nil, "08:00", "09:40", 4, 2000, 200, folded_segments: 3)

        expect(stats([legacy, two.last]).find { |l| l.start_with?("models:") }).to start_with("models:           earlier turns ")
        expect(stats([folded, two.last]).find { |l| l.start_with?("models:") }).to start_with("models:           3 earlier segments ")
      end

      it "dates the rows when they span more than one day, and leaves out a prefill's cost without a price" do
        rows = [row("a:one", "10:00", "10:30", 1, 1000, 10),
                row("b:two", "11:00", nil, 1, 2000, 20, prefill_tokens: 2000).merge(started_at: "2026-10-18T09:00:00.000Z")]

        output = stats(rows)
        expect(output).to include(a_string_including("Oct 17 10:00–Oct 17 10:30"), a_string_including("Oct 18 09:00–now"))
        expect(output).to include("                    └ switch prefill 2.0k uncached prompt")
      end
    end

    describe "the token breakdown, speed and cost" do
      def stats(tokens, snapshot = {})
        base = agent.engine.metrics.snapshot
        Samagotchi::TerminalUI::Formatting.format_session_metrics(base.merge(tokens: base[:tokens].merge(tokens)).merge(snapshot)).lines.map(&:chomp)
      end

      it "shows the server's exact speeds, the cached and reasoning counts" do
        output = stats(prompt_sum: 5210, completion_sum: 340, source: "server", cached_sum: 4864, reasoning_sum: 212,
                       last_decode_tps: 87.46, last_prefill_tps: 1904.2, tps_source: "server", avg_decode_tps: 81.2)
        expect(output).to include(
          "tokens in/out:    5210/340 (all requests, server-reported), cached 4864 (93%), reasoning 212",
          "speed:            87 tok/s out, 1.9k tok/s prompt (last, server), avg 81 tok/s"
        )
        expect(output.join("\n")).not_to include("cost:")
      end

      it "shows cache writes next to the cached count when the server reported any" do
        output = stats(prompt_sum: 30_000, completion_sum: 10, source: "server", cached_sum: 14_728, cache_write_sum: 14_728)
        expect(output).to include("tokens in/out:    30000/10 (all requests, server-reported), cached 14728 (49%), cache writes 14728")
      end

      it "shows the re-prefilled tokens when a request had any" do
        output = stats(prompt_sum: 30_000, completion_sum: 10, source: "server", cached_sum: 15_000, reprefill_sum: 2_100)
        expect(output).to include("tokens in/out:    30000/10 (all requests, server-reported), cached 15000 (50%), re-prefilled 2100")
      end

      it "marks an estimated speed with ~ and shows the cost" do
        output = stats(prompt_sum: 900, completion_sum: 60, source: "server", last_decode_tps: 64.4, tps_source: "estimate",
                       avg_decode_tps: 70.0, cost_sum: 0.4213)
        expect(output).to include("speed:            ~64 tok/s out (last, estimate), avg ~70 tok/s",
                                  "cost:             $0.42 (this session only)",
                                  "tokens in/out:    900/60 (all requests, server-reported)")
        expect(stats(cost_sum: 0.00123)).to include("cost:             $0.0012 (this session only)")
      end

      it "shows an estimated cost (hosts.<name>.models prices) with ~, apart from a reported one, naming the host" do
        expect(stats({ cost_sum: 0.42, cost_estimate_sum: 0.12 }, { price_host: "gw" }))
          .to include("cost:             $0.42 reported + ~$0.12 from hosts.gw.models prices (this session only)")
        expect(stats({ cost_estimate_sum: 0.12 }, { price_host: "gw" }))
          .to include("cost:             ~$0.12 from hosts.gw.models prices (this session only)")
        # An older worker's snapshot has no price_host.
        expect(stats(cost_estimate_sum: 0.12)).to include("cost:             ~$0.12 from configured prices (this session only)")
        expect(stats(cost_sum: 0.42, cost_estimate_sum: 0)).to include("cost:             $0.42 (this session only)")
      end

      # The side requests (recap, /btw, ctx.ask_model) on their own line,
      # never in the totals above it.
      describe "the side requests line" do
        let(:side) do
          { requests: 3, prompt_sum: 14_210, completion_sum: 380, cached_sum: 0, cache_write_sum: 0, reasoning_sum: 0,
            cost_sum: nil, cost_estimate_sum: 0.0021,
            by_kind: { "recap" => { requests: 2, cost_sum: nil, cost_estimate_sum: 0.0012 },
                       "btw" => { requests: 1, cost_sum: nil, cost_estimate_sum: 0.0009 } } }
        end
        let(:line) { "side requests:    3 (recap 2, btw 1) · 14.2k in / 380 out · ~$0.0021 (not in the totals above)" }

        it "comes right after the cost: line" do
          output = stats({ cost_sum: 0.42 }, { side: side })
          expect(output[output.index("cost:             $0.42 (this session only)") + 1]).to eq(line)
        end

        it "takes the cost: line's place when there is none" do
          output = stats({}, { side: side })
          expect(output.join("\n")).not_to include("cost:")
          expect(output[output.index(line) + 1]).to start_with("gen latency (ms):")
        end

        it "is absent without side requests (an older snapshot or analytics.json)" do
          expect(stats({ cost_sum: 0.42 }).join("\n")).not_to include("side requests")
        end

        it "reads the attached TUI's snapshot, JSON deep-symbolized, the same" do
          base = agent.engine.metrics.snapshot.merge(side: side)
          attached = Samagotchi::TerminalUI::EventRenderer.deep_symbolize_keys(JSON.parse(JSON.generate(base)))
          expect(Samagotchi::TerminalUI::Formatting.format_session_metrics(attached).lines.map(&:chomp)).to include(line)
        end
      end

      it "has no speed line before a generation had one" do
        expect(stats({}).join("\n")).not_to include("speed:")
      end
    end

    it "shows the context window and where it came from in /stats" do
      metrics = agent.engine.metrics
      metrics.call(type: :generation_started, context_window_tokens: 128_000, context_window_source: :server)

      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics(metrics.snapshot)).to include("context window:   128000 tokens (server)")
    end

    it "shows the generations plugins cut and the output cap ended in /stats" do
      output = Samagotchi::TerminalUI::Formatting.format_session_metrics(agent.engine.metrics.snapshot.merge(cuts: 2, capped: 1))

      expect(output).to include("retries:          0\nthinking cuts:    2\noutput cap hits:  1")
    end

    it "shows the thinking blocks a preserved-thinking recovery dropped, only when there were any" do
      snapshot = agent.engine.metrics.snapshot

      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics(snapshot.merge(thinking_dropped: 3)))
        .to include("output cap hits:  0\nthinking dropped: 3 blocks (preserved-thinking recovery)")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics(snapshot.merge(thinking_dropped: 0)))
        .not_to include("thinking dropped")
    end

    it "shows the served model in /stats, with the name asked for when they differ" do
      metrics = agent.engine.metrics
      output = ->(snapshot) { Samagotchi::TerminalUI::Formatting.format_session_metrics(metrics.snapshot.merge(snapshot)) }

      expect(output.call(served_model: "ornith-1.5", served_model_for: "unsloth/Qwen3.6"))
        .to include("served model:     ornith-1.5 (asked for unsloth/Qwen3.6)")
      expect(output.call(served_model: "z-ai/glm-5.2", served_model_for: "z-ai/glm-5.2:free").lines.map(&:chomp))
        .to include("served model:     z-ai/glm-5.2")
      expect(output.call(served_model: nil, served_model_for: nil)).not_to include("served model")
      expect(output.call(served_model: "fireworks/x", served_model_for: "rr/x", served_expected_by: "work").lines.map(&:chomp))
        .to include("served model:     fireworks/x")
    end

    it "shows the LLM context strategy, apply rule and budget, each with where it came from, in /stats" do
      summary = { "strategy" => "stale,forget", "strategy_where" => "the session", "apply" => "turn_end",
                  "apply_where" => "models: ds", "budget_tokens" => nil, "budget_where" => "llm_context.budget_tokens" }

      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ llm_context: summary }))
        .to include("llm context:      stale,forget (the session); apply turn_end (models: ds); budget off " \
                    "(llm_context.budget_tokens)")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({})).not_to include("llm context")
    end

    it "shows the thinking level with where it came from in /stats, string keys or symbol ones" do
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ thinking: { level: "low", source: "session", own: "low" } }))
        .to include("thinking:         low (session)")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ thinking: { "level" => "default", "source" => nil } }))
        .to include("thinking:         default")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({})).not_to include("thinking:  ")
    end

    it "shows a chat host's reasoning history with where it came from in /stats, nothing without one (a native host)" do
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ reasoning_history: { level: "all", source: "session", own: "all" } }))
        .to include("reasoning history: all (session)")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ reasoning_history: { "level" => "turn", "source" => nil } }))
        .to include("reasoning history: turn")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ reasoning_history: nil })).not_to include("reasoning history")
    end

    it "names a set budget with its tokens and where it came from, string keys or symbol ones" do
      stringy = { "strategy" => "stale", "strategy_where" => "the session", "apply" => "turn_end",
                  "apply_where" => "llm_context.apply", "budget_tokens" => 64_000, "budget_where" => "the session" }
      symbolic = { strategy: "stale", strategy_where: "the session", apply: "turn_end",
                   apply_where: "llm_context.apply", budget_tokens: 64_000, budget_where: "the session" }

      line = "llm context:      stale (the session); apply turn_end (llm_context.apply); budget 64000 tokens (the session)"
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ llm_context: stringy })).to include(line)
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ llm_context: symbolic })).to include(line)
    end

    # context used: counts against the smaller of the window and the
    # session's llm_context budget, as the live meter does, and says which.
    it "counts context used against a budget smaller than the window, and names it" do
      context = { used_tokens: 16_000, window_tokens: 128_000, window_source: "server" }
      summary = { strategy: "stale", strategy_where: "the session", apply: "turn_end",
                  apply_where: "llm_context.apply", budget_tokens: 64_000, budget_where: "the session" }
      stringy = summary.transform_keys(&:to_s)

      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ context: context, llm_context: summary }))
        .to include("context used:     16000 tokens (25.0% of the 64000 budget)")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ context: context, llm_context: stringy }))
        .to include("context used:     16000 tokens (25.0% of the 64000 budget)")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ context: context, llm_context: summary }))
        .to include("context window:   128000 tokens (server)")
    end

    it "keeps the plain percentage without a budget, for one larger than the window, and for 0" do
      context = { used_tokens: 16_000, window_tokens: 64_000, window_source: "server" }
      base = { strategy: "stale", strategy_where: "the session", apply: "turn_end", apply_where: "llm_context.apply" }

      [{}, { budget_tokens: nil }, { budget_tokens: 128_000 }, { budget_tokens: 0 }].each do |extra|
        output = Samagotchi::TerminalUI::Formatting.format_session_metrics({ context: context, llm_context: base.merge(extra) })
        expect(output).to include("context used:     16000 tokens (25.0%)"), extra.inspect
        expect(output).not_to include("budget)")
      end
      # No llm context at all (an older worker): the window, as before.
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ context: context }))
        .to include("context used:     16000 tokens (25.0%)")
    end

    it "shows the memory indexes the session's prompt holds in /stats, none from an older worker" do
      index = { "system" => { "tokens" => 1997, "lines" => 54 }, "project" => { "tokens" => 1394, "lines" => 35 } }

      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ memory_index: index }))
        .to include("memory index:     ~3.4k tokens in this session's prompt (system 2.0k, project 1.4k)")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({})).not_to include("memory index")
    end

    it "shows the model notes the session's prompt carried in /stats, none without any" do
      notes = [{ "name" => "model_notes_deepseek", "scope" => "system", "chars" => 612, "digest" => "0123456789ab" }]

      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ prompt_notes: notes }))
        .to include("model notes:      model_notes_deepseek (system, 612 chars)")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ prompt_notes: [] })).not_to include("model notes")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({})).not_to include("model notes")
    end

    it "shows the files whose text is in the session's prompt in /stats, relative to the checkout" do
      # The checkout this process runs in, stubbed: the suite may run outside a git work tree.
      top = "/work/checkout"
      allow(Samagotchi::MemoryPaths).to receive(:work_tree_root).with(Dir.pwd).and_return(top)
      files = [File.join(top, "AGENTS.md"), File.join(top, "lib", "AGENTS.md"), File.join(Dir.home, "notes", "x.md")]

      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ prompt_files: files }))
        .to include("prompt files:     AGENTS.md, lib/AGENTS.md, ~/notes/x.md")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({ prompt_files: [] })).not_to include("prompt files")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({})).not_to include("prompt files")
    end

    it "shows the toolkit's prompt text in /stats as its kit and tokens, nothing without one" do
      text = Samagotchi::TerminalUI::Formatting.format_session_metrics({ prompt_files: [File.join(Dir.home, "x.md")], kit_prompt: { kit: "coding", tokens: 15 } })
      expect(text).to include("prompt files:     ~/x.md\nkit prompt:       coding (~15 tokens)")
      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics({})).not_to include("kit prompt")
    end

    it "shows the prompt profile and where it came from in /stats" do
      metrics = agent.engine.metrics
      metrics.call(type: :generation_started, profile: "qwen36", profile_source: "config (models: ista)")

      expect(Samagotchi::TerminalUI::Formatting.format_session_metrics(metrics.snapshot)).to include("prompt profile:   qwen36 (config (models: ista))")
    end
  end

  describe "timing output" do
    # Shared contract: spec/shared/timing_matrix.json. One source of truth for
    # the web (JS) and TUI (Ruby) suites — edit it to change either side's output.
    let(:timing_matrix) do
      path = File.expand_path("shared/timing_matrix.json", __dir__)
      JSON.parse(File.read(path))["cases"]
    end

    it "adds compact elapsed time to a completed tool activity line" do
      output = agent.send(
        :format_tool_activity_line,
        { action: "reading file", tool: "read", params: "path=README.md", status: "ok" },
        duration_ms: 125
      )

      expect(output).to include("tool>")
      expect(output).to include("ok")
      expect(output).to include("(125ms)")
    end

    it "says, dim, when the model called the tool by an alias's name" do
      allow(agent).to receive(:paint) { |text, code| "<#{code}>#{text}" }
      line = lambda do |extra|
        agent.send(:format_tool_activity_line,
                   { action: "running command", tool: "execute", description: "List the specs", status: "ok" }.merge(extra))
      end

      expect(line.call(called_as: "bash")).to include("(execute: List the specs<90> (called as bash)): ")
      expect(line.call({})).not_to include("called as")
      expect(line.call(via: "call_tool")).to include("(execute: List the specs<90> (via call_tool)): ")
    end

    it "shows a wait the user's Stop ended as stopped, in yellow" do
      allow(agent).to receive(:paint) { |text, code| "<#{code}>#{text}" }
      output = agent.send(
        :format_tool_activity_line,
        { action: "waiting for task", tool: "task_wait", params: "", status: "stopped" },
        duration_ms: 17_000
      )

      expect(output).to end_with("<33>stopped (17s)")
    end

    it "formats durations per the shared timing matrix" do
      timing_matrix.each do |case_entry|
        ms = case_entry["ms"]
        expected = case_entry["expected"]
        expect(agent.send(:format_elapsed_duration, ms)).to eq(expected),
                                                            "timing for #{ms}ms expected #{expected.inspect}"
      end
    end
  end
end
