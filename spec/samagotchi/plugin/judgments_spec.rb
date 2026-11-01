# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "samagotchi/testing"
require "samagotchi/bundle_command/check"

# chi.judgment, ctx.judge, ctx.judge_later and ctx.judgments through the bundle
# test kit: chi's real API, Context, Judgments, Client, Recording and Runs, on
# a FakeBackend. The Engine's wiring is judgments_engine_spec.rb's.
RSpec.describe "chi.judgment and ctx.judge" do
  let(:dir) { Dir.mktmpdir("judgment-bundle") }
  let(:noul) { 'chi.judgment "progress", questions: { "progress" => { type: "noul", instructions: "Still going?" } }' }

  after do
    @bundle&.shutdown
    FileUtils.rm_rf(dir)
  end

  def bundle_with(register, host: {})
    File.write(File.join(dir, "manifest.yml"), <<~YAML)
      name: probe
      version: 0.1.0
      plugin:
        file: plugin.rb
    YAML
    File.write(File.join(dir, "plugin.rb"), <<~RUBY)
      class Plugin
        def initialize(_settings); end
        def register(chi)
          #{register}
        end
      end
    RUBY
    @bundle = Samagotchi::Testing::Bundle.load(dir, host: host)
  end

  def declared(extra = "", host: {})
    bundle_with("#{noul}#{extra}", host: host)
  end

  def judgments = @bundle.judgments
  def ctx = @bundle.ctx

  describe "chi.judgment" do
    it "scopes the name to the bundle" do
      declared
      judgments.answer("progress", noul: 0.9)
      expect(ctx.judge("progress", state: "s").run_id).to start_with("probe.progress/")
    end

    it "refuses a second declaration, a bad name, a bad shared_host and bad questions: the plugin fails to load" do
      question = '{ "q" => { type: "noul", instructions: "i" } }'
      [
        ["#{noul}\n#{noul}", /declared twice/],
        [%(chi.judgment "Bad Name", questions: #{question}), /dot-separated/],
        [%(chi.judgment "x.replay", questions: #{question}), /replay/],
        [%(chi.judgment "x", questions: #{question}, shared_host: :after_turn), /shared_host/],
        [%(chi.judgment "x", questions: { "q" => { type: "nope", instructions: "i" } }), /type must be/],
        [%(chi.judgment "x", questions: {}), /no questions/]
      ].each do |register, message|
        expect { bundle_with(register) }.to raise_error(StandardError, message), register
      end
    end

    it "refuses a bundle named like core's judgments" do
      declaration = Samagotchi::SystemOne::Judgments::Declaration
      question = { "q" => { type: "noul", instructions: "i" } }
      %w[approvals context guardrails toolkit].each do |bundle|
        expect { declaration.build(bundle: bundle, name: "allow", questions: question) }.to raise_error(ArgumentError, /first word/)
      end
    end

    it "builds the questions at each ask from a callable given the ctx" do
      bundle_with(%(chi.judgment "x", questions: ->(ctx) { { "q" => { type: "noul", instructions: "in \#{ctx.session_id}" } } }))
      judgments.answer("x", noul: 0.5)
      ctx.judge("x", state: "s")
      expect(judgments.asks.last.questions.map(&:instructions)).to eq(["in test-session"])
    end

    it "keeps the label values a later comparison reads in each run" do
      declared(%(\nchi.judgment "y", questions: { "q" => { type: "noul", instructions: "i" } }, positive: "keep_going", negative: %w[stop nudge]))
      judgments.answer("y", noul: 0.5)
      ctx.judge("y", state: "s")
      expect(judgments.runs("y").last).to include("positive" => ["keep_going"], "negative" => %w[stop nudge])
      judgments.answer("progress", noul: 0.5)
      ctx.judge("progress", state: "s")
      expect(judgments.runs("progress").last).not_to include("positive", "negative")
    end
  end

  describe "ctx.judge" do
    it "gives the answers, p, the run id and the mode, and saves the run as sent" do
      declared(host: { model_name: "main:big" })
      judgments.answer("progress", noul: 0.9).mode("progress", "audit")
      result = ctx.judge("progress", state: { "turn" => "the state" })

      expect(result).to have_attributes(no_judgment?: false, audit?: true, reason: nil, run_id: start_with("probe.progress/"))
      expect(result.p).to eq(0.9)
      expect(result.p("progress")).to eq(0.9)
      expect(result.p(:progress)).to eq(0.9)
      expect(result.p("other")).to be_nil
      expect(result.answers["progress"].noul).to eq(0.9)
      expect(judgments.runs("progress").last).to include(
        "id" => result.run_id, "judgment" => "probe.progress", "asked" => true, "origin" => "live", "mode" => "audit",
        "state" => { "turn" => "the state" }, "session_id" => "test-session", "session_model" => "main:big", "host" => "fake"
      )
    end

    it "reads a choice and a score by their answers; p is a noul's alone, and with no id only with one question" do
      bundle_with(<<~RUBY)
        chi.judgment "x", questions: { "c" => { type: "choice", instructions: "i", criteria: { "a" => nil } },
                                       "n" => { type: "noul", instructions: "i" } }
      RUBY
      judgments.answer("x", question: "c", choice: "a", confidence: 0.7).answer("x", question: "n", noul: 0.2)
      result = ctx.judge("x", state: "s")
      expect(result.answers["c"].choice).to eq("a")
      expect(result.p("c")).to be_nil
      expect(result.p("n")).to eq(0.2)
      expect(result.p).to be_nil
    end

    it "scrubs bytes that aren't UTF-8 from the state before it goes anywhere" do
      declared
      judgments.answer("progress", noul: 0.5)
      ctx.judge("progress", state: "bad \xFF byte")
      expect(judgments.asks.last.state).to eq("bad � byte")
    end

    it "raises ArgumentError, not a SystemStackError past the hook's rescue, for a state nested without end" do
      declared
      cycle = {}
      cycle["self"] = cycle
      expect { ctx.judge("progress", state: cycle) }.to raise_error(ArgumentError, /nested too deep/)
      expect { ctx.judge_later("progress", state: cycle) }.to raise_error(ArgumentError, /nested too deep/)
    end

    it "raises ArgumentError for a name it didn't declare, as ask_model does, and for a state it can't send" do
      declared
      expect { ctx.judge("other", state: "s") }.to raise_error(ArgumentError, /no judgment probe.other declared/)
      expect { ctx.judge("progress", state: nil) }.to raise_error(ArgumentError, /state:/)
      expect { ctx.judge("progress", state: 3) }.to raise_error(ArgumentError, /state:/)
      expect(judgments.asks).to be_empty
    end

    it "reaches no other bundle's judgment" do
      declared
      expect { ctx.judge("probe.progress", state: "s") }.to raise_error(ArgumentError, /no judgment/)
    end

    it "is a no_judgment Result with no run while off, asking nothing" do
      declared
      judgments.mode("progress", "off")
      expect(ctx.judge("progress", state: "s")).to have_attributes(no_judgment?: true, reason: :off, run_id: nil, audit?: false)
      expect(judgments.asks).to be_empty
      expect(judgments.runs("progress")).to be_empty
    end

    it "is a no_judgment Result with no run with no host" do
      declared
      judgments.no_host("progress")
      expect(ctx.judge("progress", state: "s")).to have_attributes(no_judgment?: true, reason: :no_host, run_id: nil)
      expect(judgments.runs("progress")).to be_empty
    end

    it "is a no_judgment Result with no run with no session" do
      declared(host: { session_id: nil })
      expect(ctx.judge("progress", state: "s")).to have_attributes(no_judgment?: true, reason: :no_session, run_id: nil)
    end

    it "is a no_judgment Result, no raise, on a failed backend, whose run says why" do
      declared
      judgments.fail("progress", error: "down")
      result = ctx.judge("progress", state: "s")
      expect(result).to have_attributes(no_judgment?: true, reason: :failed, run_id: start_with("probe.progress/"))
      expect(judgments.runs("progress").last).to include("id" => result.run_id, "failure" => "Samagotchi::SystemOne::BackendError",
                                                         "failure_text" => include("down"), "asked" => true)
    end

    it "is a no_judgment Result when a question goes unanswered" do
      declared
      expect(ctx.judge("progress", state: "s")).to have_attributes(no_judgment?: true, reason: :failed)
      expect(judgments.runs("progress").last).to include("failure" => "no_answer")
    end

    it "stops with the running turn: a cancelled ask keeps its run and is no raise" do
      declared(host: { cancelled: true })
      judgments.answer("progress", noul: 0.9)
      result = ctx.judge("progress", state: "s")
      expect(result).to have_attributes(no_judgment?: true, reason: :cancelled)
      expect(judgments.asks.last.cancel).to be_cancelled
      expect(judgments.runs("progress").last).to include("failure" => "cancelled")
    end

    it "skips while a turn runs on the shared host, saving the run asked: false" do
      declared
      judgments.answer("progress", noul: 0.9).shared_host_busy
      result = ctx.judge("progress", state: "the state")
      expect(result).to have_attributes(no_judgment?: true, reason: :shared_host, run_id: start_with("probe.progress/"))
      expect(judgments.asks).to be_empty
      expect(judgments.runs("progress").last).to include("id" => result.run_id, "asked" => false, "skipped" => "shared_host",
                                                         "state" => "the state", "mode" => "on", "host" => "fake")
      expect(judgments.runs("progress").last).not_to include("answers", "latency_ms")
    end

    it "asks anyway under shared_host: :ask" do
      bundle_with(%(chi.judgment "x", questions: { "q" => { type: "noul", instructions: "i" } }, shared_host: :ask))
      judgments.answer("x", noul: 0.9).shared_host_busy
      expect(ctx.judge("x", state: "s").p).to eq(0.9)
    end

    it "raises in a :generation_progress handler, whose stream it would hold, pointing to ctx.judge_later" do
      declared(%(\nchi.on(:generation_progress) { |_event, ctx| ctx.judge("progress", state: "s") }))
      expect { @bundle.fire(:generation_progress, thinking: "", text: "") }
        .to raise_error(Samagotchi::Testing::HookFailed, /ctx.judge_later/)
      expect(judgments.asks).to be_empty
    end

    it "lets another hook ask" do
      declared(%(\nchi.on(:after_turn) { |_event, ctx| ctx.judge("progress", state: "s") }))
      judgments.answer("progress", noul: 0.9)
      @bundle.fire(:after_turn, status: "completed")
      expect(judgments.asks.size).to eq(1)
    end

    it "saves nothing for a scratch session" do
      declared(host: { scratch: true })
      judgments.answer("progress", noul: 0.9)
      expect(ctx.judge("progress", state: "s")).to have_attributes(no_judgment?: false, run_id: nil)
      expect(judgments.runs("progress")).to be_empty
    end

    it "saves nothing in a participant's turn" do
      declared(host: { turn_author: "p:p_0123abcd" })
      judgments.answer("progress", noul: 0.9)
      expect(ctx.judge("progress", state: "their text")).to have_attributes(no_judgment?: false, run_id: nil)
      expect(judgments.runs("progress")).to be_empty
    end
  end

  describe "ctx.judge_later" do
    it "gives the run's id at once and the Result off this thread" do
      declared
      judgments.answer("progress", noul: 0.9)
      got = Queue.new
      id = ctx.judge_later("progress", state: "s") { |result| got << [result, Thread.current] }
      expect(id).to start_with("probe.progress/")
      result, thread = got.pop(timeout: 5)
      expect(result).to have_attributes(run_id: id, reason: nil)
      expect(result.p).to eq(0.9)
      expect(thread).not_to eq(Thread.current)
      judgments.wait
      expect(judgments.runs("progress").last).to include("id" => id, "asked" => true)
      expect(judgments.asks.last.cancel).to be_nil
    end

    it "works from a :generation_progress handler" do
      declared(%(\nchi.on(:generation_progress) { |_event, ctx| ctx.judge_later("progress", state: "s") }))
      judgments.answer("progress", noul: 0.9)
      @bundle.fire(:generation_progress, thinking: "", text: "")
      expect(judgments.wait.runs("progress").size).to eq(1)
    end

    it "takes no block too" do
      declared
      judgments.answer("progress", noul: 0.9)
      expect(ctx.judge_later("progress", state: "s")).to be_a(String)
      expect(judgments.wait.runs("progress").size).to eq(1)
    end

    it "skips while its kind is busy: no ask, a skipped run, the block told with no answers" do
      declared
      hold = Queue.new
      entered = Queue.new
      judgments.answer("progress") do |_state|
        entered << true
        hold.pop(timeout: 5)
        { noul: 0.9 }
      end
      first = Queue.new
      second = Queue.new
      first_id = ctx.judge_later("progress", state: "one") { |result| first << result }
      entered.pop(timeout: 5)
      second_id = ctx.judge_later("progress", state: "two") { |result| second << result }

      told = second.pop(timeout: 5)
      expect(told).to have_attributes(no_judgment?: true, reason: :busy, run_id: second_id)
      expect(judgments.asks.map(&:state)).to eq(["one"])
      expect(judgments.runs("progress").map { |run| [run["id"], run["asked"], run["skipped"], run["state"]] })
        .to eq([[second_id, false, "busy", "two"]])

      hold << :go
      expect(first.pop(timeout: 5).p).to eq(0.9)
      expect(judgments.wait.runs("progress").map { |run| run["id"] }).to contain_exactly(first_id, second_id)
    end

    it "tells the block off this thread and returns nil when off" do
      declared
      judgments.mode("progress", "off")
      got = Queue.new
      expect(ctx.judge_later("progress", state: "s") { |result| got << [result, Thread.current] }).to be_nil
      result, thread = got.pop(timeout: 5)
      expect(result).to have_attributes(reason: :off, no_judgment?: true)
      expect(thread).not_to eq(Thread.current)
    end

    it "tells the block and returns nil with no host" do
      declared
      judgments.no_host("progress")
      got = Queue.new
      expect(ctx.judge_later("progress", state: "s") { |result| got << result }).to be_nil
      expect(got.pop(timeout: 5)).to have_attributes(reason: :no_host)
    end

    it "answers and returns nil with no run to save (a scratch session)" do
      declared(host: { scratch: true })
      judgments.answer("progress", noul: 0.9)
      got = Queue.new
      expect(ctx.judge_later("progress", state: "s") { |result| got << result }).to be_nil
      expect(got.pop(timeout: 5).p).to eq(0.9)
      expect(judgments.wait.runs("progress")).to be_empty
    end

    it "skips under shared_host: :skip with the block told" do
      declared
      judgments.answer("progress", noul: 0.9).shared_host_busy
      got = Queue.new
      id = ctx.judge_later("progress", state: "s") { |result| got << result }
      expect(got.pop(timeout: 5)).to have_attributes(reason: :shared_host, run_id: id)
      expect(judgments.runs("progress").last).to include("id" => id, "asked" => false)
      expect(judgments.asks).to be_empty
    end

    it "tells the block on a failed backend, and a failed ask frees the kind" do
      declared
      judgments.fail("progress")
      got = Queue.new
      ctx.judge_later("progress", state: "s") { |result| got << result }
      expect(got.pop(timeout: 5)).to have_attributes(reason: :failed)
      judgments.wait.answer("progress", noul: 0.9)
      ctx.judge_later("progress", state: "s") { |result| got << result }
      expect(got.pop(timeout: 5).p).to eq(0.9)
    end

    it "logs a block that raises, and it costs the session nothing" do
      declared
      judgments.answer("progress", noul: 0.9)
      expect(Samagotchi::Log).to receive(:warn).with(:plugins, "judge_later_block_failed", hash_including(judgment: "probe.progress", error: include("boom")))
      ctx.judge_later("progress", state: "s") { raise "boom" }
      judgments.wait
    end

    it "raises at once for a name it didn't declare" do
      declared
      expect { ctx.judge_later("other", state: "s") { nil } }.to raise_error(ArgumentError, /no judgment/)
    end
  end

  describe "ctx.judgments" do
    before do
      declared
      judgments.answer("progress", noul: 0.9)
    end

    let(:run_id) { ctx.judge("progress", state: "s").run_id }

    it "labels the bundle's run in the bundle's name, the bundle's own word kept raw" do
      expect(ctx.judgments.label(run_id, "keep_going")).to be(true)
      expect(ctx.judgments.label(run_id, "stop", by: "card", strength: "weak", question: "progress")).to be(true)
      expect(judgments.labels("progress").map { |line| line.slice("run_id", "value", "by", "strength", "question") })
        .to eq([{ "run_id" => run_id, "value" => "keep_going", "by" => "probe" },
                { "run_id" => run_id, "value" => "stop", "by" => "probe:card", "strength" => "weak", "question" => "progress" }])
    end

    it "says what the bundle did" do
      expect(ctx.judgments.acted(run_id, "nudged")).to be(true)
      expect(judgments.acted_lines("progress").last).to include("run_id" => run_id, "what" => "nudged")
    end

    it "refuses another bundle's run, core's among them" do
      ["other.progress/abc", "approvals.allow/abc", "probe-other.x/abc", "probe.nope/abc", "probe.nope.replay/abc", "garbage"].each do |id|
        expect { ctx.judgments.label(id, "v") }.to raise_error(ArgumentError, /not a run of bundle probe's/), id
        expect { ctx.judgments.acted(id, "v") }.to raise_error(ArgumentError, /not a run of bundle probe's/), id
      end
      expect(judgments.labels("progress")).to be_empty
    end

    it "gives a bundle named like core's nothing of core's, and one with a dot no judgment" do
      question = { "q" => { type: "noul", instructions: "i" } }
      expect { Samagotchi::SystemOne::Judgments::Declaration.build(bundle: "a.b", name: "x", questions: question) }.to raise_error(ArgumentError, /dot/)
      layer = Samagotchi::SystemOne::Judgments.new(runs: -> { Samagotchi::SystemOne::Runs.new(store: Samagotchi::SystemOne::Runs::MemoryStore.new) })
      labels = Samagotchi::Plugin::Judgments.new(-> { layer }, bundle: "approvals")
      expect { labels.label("approvals.allow/abc", "allow_wide", strength: "strong") }.to raise_error(ArgumentError, /not a run of bundle approvals's/)
    end

    it "saves no later line in a participant's turn" do
      id = run_id
      @bundle.set(turn_author: "p:p_0123abcd")
      expect(ctx.judgments.label(id, "v")).to be(false)
      expect(ctx.judgments.acted(id, "v")).to be(false)
      expect(judgments.labels("progress") + judgments.acted_lines("progress")).to be_empty
    end

    it "takes the nil a run that wasn't saved gives, saving nothing" do
      expect(ctx.judgments.label(nil, "v")).to be(false)
      expect(ctx.judgments.acted(nil, "v")).to be(false)
    end

    it "refuses a value it can't keep and a strength it doesn't have" do
      expect { ctx.judgments.label(run_id, "") }.to raise_error(ArgumentError, /label takes/)
      expect { ctx.judgments.label(run_id, :word) }.to raise_error(ArgumentError, /label takes/)
      expect { ctx.judgments.label(run_id, "x" * 201) }.to raise_error(ArgumentError, /label takes/)
      expect { ctx.judgments.label(run_id, "v", strength: "very") }.to raise_error(ArgumentError, /strength/)
      expect { ctx.judgments.label(run_id, "v", question: "x" * 201) }.to raise_error(ArgumentError, /question takes/)
    end

    it "saves no line for a scratch session" do
      id = run_id
      @bundle.set(scratch: true)
      expect(ctx.judgments.label(id, "v")).to be(false)
      expect(judgments.labels("progress")).to be_empty
    end
  end

  it "gives chi bundle check a floor for each call, as the source writes it" do
    check = Samagotchi::BundleCommand::Check
    source = 'chi.judgment "x"; ctx.judge("x"); ctx.judge_later("x"); ctx.judgments.label(id, "v")'
    calls = source.scan(check::API_CALL).flat_map { |call| [call, call.split(".").first(2).join(".")] }.uniq
    expect(calls.select { |call| Samagotchi::Plugin::Api::SINCE.key?(call) }).to contain_exactly("chi.judgment", "ctx.judge", "ctx.judge_later", "ctx.judgments")
  end

  it "records the declaration for a spec of what #register declares" do
    declared
    expect(@bundle.declarations.map(&:name)).to include(:judgment)
  end
end
