# frozen_string_literal: true

require "json"
require "yaml"
require "spec_helper"
require "samagotchi/broadcast/triage"
require "samagotchi/broadcast/scope_card"

module BroadcastTriageSpec
  # An IdleClient stand-in: answers each request with the block's Summary.
  class FakeClient
    attr_reader :asked

    def initialize(&answer)
      @answer = answer
      @asked = []
    end

    def ask(messages, max_tokens:, cancel_controller:, kind:, options:)
      @asked << { messages: messages, max_tokens: max_tokens, kind: kind, options: options }
      @answer.call(messages, options, cancel_controller)
    end
  end
end

RSpec.describe Samagotchi::Broadcast::Triage do
  def card(id, project: "app", tags: [], title: id)
    Samagotchi::Broadcast::ScopeCard.new(id: id, project: project, folder: nil, branch: nil, title: title, tags: tags, started: nil, recap: nil,
                                         recent: nil)
  end

  def target(base_url = "http://triage.test/v1")
    Samagotchi::IdleTarget.new(base_url: base_url, api_key_env: nil, model: "small", label: "small")
  end

  def llm(client, base_url: "http://triage.test/v1", threshold: 0.5)
    described_class::LLM.new(target: target(base_url), timeout: 5, threshold: threshold, client: client)
  end

  def logprobs(yes, no = nil)
    top = [Samagotchi::LLM::TokenLogprob.new(token: "yes", logprob: Math.log(yes))]
    top << Samagotchi::LLM::TokenLogprob.new(token: " No", logprob: Math.log(no || (1 - yes))) if (no || (1 - yes)).positive?
    top
  end

  before { described_class::LLM.reset_logprobs! }

  # The spike's 21 notes x 20 cards with the answers three models gave
  # (recorded, no live model): the tags fast path, the scope line and the
  # model's answer, as chi broadcast decides them.
  describe "the spike's labelled notes, replayed" do
    fixtures = File.expand_path("../fixtures/broadcast_triage", __dir__)
    let(:notes) { YAML.load_file(File.join(fixtures, "notes.yml")) }
    let(:answers) { JSON.parse(File.read(File.join(fixtures, "answers.json"))) }
    let(:cards) do
      YAML.load_file(File.join(fixtures, "cards.yml")).map do |raw|
        tags = (raw["tags"] || {}).flat_map do |kind, values|
          values.map { |value| Samagotchi::Broadcast::Tag.new(kind: kind, value: value, from: kind == "pr" ? "context pr-#{value[1..]}" : "branch") }
        end
        project = raw["project"] == "(none)" ? nil : raw["project"]
        Samagotchi::Broadcast::ScopeCard.new(id: raw["id"], project: project, folder: nil, branch: (raw["branch"] unless project.nil?),
                                             title: raw["title"], tags: tags, started: raw["started"], recap: raw["recap"], recent: raw["recent"])
      end
    end

    # @return [Array(Integer, Integer, Integer)] misses (of 19 must-get),
    #   wrong deliveries (of 377 should-not), model calls
    def score(model, threshold: 0.5)
      recorded = answers.fetch(model)
      note_ids = notes.to_h { |n| [n["text"], n["id"]] }
      card_ids = cards.to_h { |c| [c.to_s, c.id] }
      calls = 0
      misses = 0
      wrong = 0
      notes.each do |note|
        client = BroadcastTriageSpec::FakeClient.new do |messages, _options|
          calls += 1
          note_text, card_text = messages.last[:content].delete_prefix("NOTE:\n").split("\n\nSESSION CARD:\n", 2)
          answer = recorded.fetch(note_ids.fetch(note_text)).fetch(card_ids.fetch(card_text))
          if answer.is_a?(String)
            Samagotchi::IdleClient::Summary.new(text: answer, model: nil)
          else
            Samagotchi::IdleClient::Summary.new(text: answer >= 0.5 ? "yes" : "no", model: nil,
                                                top_logprobs: logprobs(answer))
          end
        end
        tags = Samagotchi::Broadcast::Tags.of_text(note["text"], from: "note")
        verdicts = described_class.verdicts(note["text"], cards, note_tags: tags, new_backend: ->(_) { llm(client, threshold: threshold) })
        cards.each do |c|
          delivered = verdicts.fetch(c.id).relevant
          misses += 1 if note["must"].include?(c.id) && !delivered
          wrong += 1 if delivered && !note["must"].include?(c.id) && !note["maybe"].include?(c.id)
        end
      end
      [misses, wrong, calls]
    end

    it "misses no recipient with qwen3.5-9b's yes/no, and the scope line removes the spike's agentd-web extras" do
      # spike: 0 misses, 20 wrong deliveries; the N18 scope line ("agentd web") narrows 2 of them away
      # 3 pairs share a tag; 4 scope lines skip 54 sessions of other projects
      expect(score("qwen3.5-9b yes/no")).to eq([0, 18, 420 - 3 - 54])
    end

    it "grades qwen3.5-9b's logprob p by the threshold: higher drops real recipients first" do
      expect(score("qwen3.5-9b logprob p").first(2)).to eq([0, 19])
      expect(score("qwen3.5-9b logprob p", threshold: 0.9).first(2)).to eq([4, 3])
    end

    it "misses no recipient with splash's Qwen3.6-35B-A3B, a bit noisier" do
      # spike: 30 wrong deliveries without the scope line
      expect(score("splash Qwen3.6-35B-A3B yes/no").first(2)).to eq([0, 25])
    end
  end

  describe ".verdicts" do
    let(:note_tags) { [Samagotchi::Broadcast::Tag.new(kind: "ticket", value: "PAY-1", from: "note")] }

    it "delivers on a shared tag without the model, skips other projects for a scope line, asks the model the rest" do
      cards = [card("tagged", project: "web", tags: [Samagotchi::Broadcast::Tag.new(kind: "ticket", value: "PAY-1", from: "branch")]),
               card("same", project: "shop"), card("other", project: "web"), card("none", project: nil)]
      client = BroadcastTriageSpec::FakeClient.new { Samagotchi::IdleClient::Summary.new(text: "no", model: nil) }

      verdicts = described_class.verdicts("shop/checkout\n> PAY-1 is done", cards, note_tags: note_tags,
                                                                                 new_backend: ->(_) { llm(client) })

      expect(verdicts.transform_values { |v| [v.relevant, v.by, v.reason] }).to eq(
        "tagged" => [true, "tags", "ticket PAY-1 matches (branch)"], "same" => [false, "model", "model: no"],
        "other" => [false, "scope", "scope line names shop"], "none" => [false, "scope", "scope line names shop"]
      )
      expect(verdicts.fetch("tagged").match.because).to eq("ticket PAY-1 matches your branch")
      expect(client.asked.size).to eq(1)
    end
  end

  describe ".scope_project" do
    it "is the one project the first line names as a whole word, in any case" do
      projects = %w[shopfront agentd infra web]
      expect(described_class.scope_project("Shopfront/checkout\n> x", projects)).to eq("shopfront")
      expect(described_class.scope_project("infra / ci\n> x", projects)).to eq("infra")
      expect(described_class.scope_project("agentd web\n> x", projects)).to be_nil
      expect(described_class.scope_project("for payments folks\n> shopfront", projects)).to be_nil
      expect(described_class.scope_project("webhooks are down", projects)).to be_nil
    end
  end

  describe "LLM" do
    let(:messages_seen) { [] }

    it "asks with the yes/no prompt, a few tokens and logprobs, and grades P(yes) against the threshold" do
      client = BroadcastTriageSpec::FakeClient.new { Samagotchi::IdleClient::Summary.new(text: "yes", model: nil, top_logprobs: logprobs(0.64)) }
      verdict = llm(client).judge("payments API returns 500", card("pay"))

      expect(verdict.to_h).to eq(relevant: true, p: 0.64, reason: "model: yes (p 0.64)", by: "model", match: nil)
      asked = client.asked.last
      expect(asked).to include(max_tokens: described_class::LLM::MAX_TOKENS, kind: "broadcast",
                               options: { logprobs: true, top_logprobs: 5 })
      expect(asked[:messages].first[:content]).to end_with("Answer with exactly one word: yes or no.\n")
      expect(asked[:messages].last[:content]).to eq("NOTE:\npayments API returns 500\n\nSESSION CARD:\nproject: app\ntitle:   pay")
      expect(llm(client, threshold: 0.7).judge("x", card("pay")).to_h).to include(relevant: false, reason: "model: no (p 0.64)")
    end

    it "takes a plain yes or no without logprobs as 1.0 or 0.0, thinking and punctuation left out" do
      { "Yes." => [true, 1.0], "<think>\nhmm\n</think>\n\nno" => [false, 0.0], "**No**" => [false, 0.0] }.each do |text, (relevant, p)|
        verdict = llm(BroadcastTriageSpec::FakeClient.new { Samagotchi::IdleClient::Summary.new(text: text, model: nil) }).judge("x", card("c"))
        expect([verdict.relevant, verdict.p, verdict.by]).to eq([relevant, p, "model"]), text
      end
    end

    it "takes the logprob p only when the first token is the answer itself, else the plain yes or no" do
      top = [Samagotchi::LLM::TokenLogprob.new(token: "**", logprob: Math.log(0.9)),
             Samagotchi::LLM::TokenLogprob.new(token: "Yes", logprob: Math.log(0.05))]
      bold = llm(BroadcastTriageSpec::FakeClient.new { Samagotchi::IdleClient::Summary.new(text: "**No**", model: nil, top_logprobs: top) })
      sampled = llm(BroadcastTriageSpec::FakeClient.new do
        Samagotchi::IdleClient::Summary.new(text: "no", model: nil, top_logprobs: logprobs(0.6))
      end)

      expect(bold.judge("x", card("c")).to_h).to include(relevant: false, p: 0.0, reason: "model: no")
      expect(sampled.judge("x", card("c")).to_h).to include(relevant: false, p: 0.0, reason: "model: no")
    end

    it "delivers unchecked when the answer is no yes or no, or the request fails" do
      odd = llm(BroadcastTriageSpec::FakeClient.new { Samagotchi::IdleClient::Summary.new(text: "It depends on the session", model: nil) }).judge("x", card("c"))
      failed = llm(BroadcastTriageSpec::FakeClient.new { raise Samagotchi::IdleClient::SummarizeError, "connection refused" }).judge("x", card("c"))

      expect(odd.to_h).to eq(relevant: true, p: nil, reason: "unchecked: the model answered \"It depends on the session\"",
                             by: "fallback", match: nil)
      expect([failed.relevant, failed.by, failed.reason]).to eq([true, "fallback", "unchecked: the model failed (connection refused)"])
    end

    it "asks again without logprobs when the host refuses them, and leaves them out for that host after" do
      client = BroadcastTriageSpec::FakeClient.new do |_, options|
        raise Samagotchi::IdleClient::SummarizeError, "400" if options.key?(:logprobs)

        Samagotchi::IdleClient::Summary.new(text: "no", model: nil)
      rescue Samagotchi::IdleClient::SummarizeError
        begin
          raise Samagotchi::LLM::BadRequest, "n and logprobs are not currently supported"
        rescue Samagotchi::LLM::BadRequest
          raise Samagotchi::IdleClient::SummarizeError, "the model request failed"
        end
      end

      2.times { expect(llm(client).judge("x", card("c")).reason).to eq("model: no") }
      expect(client.asked.map { |a| a[:options] }).to eq([{ logprobs: true, top_logprobs: 5 }, {}, {}])
      llm(client, base_url: "http://other.test/v1").judge("x", card("c"))
      expect(client.asked.last(2).map { |a| a[:options] }).to eq([{ logprobs: true, top_logprobs: 5 }, {}])
    end

    # A SummarizeError caused by a 400 saying +message+.
    def bad_request(message)
      raise Samagotchi::LLM::BadRequest, message
    rescue Samagotchi::LLM::BadRequest
      raise Samagotchi::IdleClient::SummarizeError, "the model request failed"
    end

    it "keeps logprobs for a host whose 400 wasn't about them: the retry without them failed too" do
      client = BroadcastTriageSpec::FakeClient.new { bad_request("prompt is too long") }

      2.times { expect(llm(client).judge("x", card("c"))).to be_unchecked }
      expect(client.asked.map { |a| a[:options] }).to eq([{ logprobs: true, top_logprobs: 5 }, {}] * 2)
    end

    it "leaves logprobs out for a host whose 400 names something else when the retry without them answers" do
      client = BroadcastTriageSpec::FakeClient.new do |_, options|
        bad_request("unsupported parameter") if options.key?(:logprobs)

        Samagotchi::IdleClient::Summary.new(text: "yes", model: nil)
      end

      2.times { expect(llm(client).judge("x", card("c")).reason).to eq("model: yes") }
      expect(client.asked.map { |a| a[:options] }).to eq([{ logprobs: true, top_logprobs: 5 }, {}, {}])
    end
  end

  describe ".judge_all" do
    # A backend whose answer for a card waits on +gates+[id] (a Queue), if any.
    def gated_backend(gates, running, peak)
      lambda do |cancel|
        Class.new do
          define_method(:judge) do |_note, c|
            running << c.id
            peak[0] = [peak[0], running.size].max
            gate = gates[c.id]
            if gate
              sleep 0.01 until cancel.cancelled? || !gate.empty?
              raise Samagotchi::LLM::RequestCancelled, "cancelled" if cancel.cancelled?
            end
            Samagotchi::Broadcast::Triage::Verdict.new(relevant: false, p: 0.0, reason: "model: no", by: "model")
          ensure
            running.delete(c.id)
          end
        end.new
      end
    end

    it "asks at most parallel at a time, and delivers unchecked what the deadline leaves unjudged" do
      cards = %w[a b c d e].map { |id| card(id) }
      running = []
      peak = [0]
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      verdicts = described_class.judge_all("x", cards, new_backend: gated_backend({ "b" => Queue.new }, running, peak),
                                                       parallel: 2, deadline: 0.3)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 2
      expect(verdicts.transform_values(&:reason)).to eq("a" => "model: no", "b" => "unchecked: triage deadline",
                                                        "c" => "model: no", "d" => "model: no", "e" => "model: no")
      expect(verdicts.fetch("b")).to be_unchecked
      expect(peak[0]).to eq(2)
    end

    it "gives the threads still asking one shared grace past the deadline, not one each" do
      stub_const("#{described_class}::JOIN_GRACE", 0.3)
      stuck = Object.new
      # Ignores the cancel.
      def stuck.judge(_note, _card) = sleep(10)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      verdicts = described_class.judge_all("x", %w[a b c d].map { |id| card(id) }, new_backend: ->(_) { stuck },
                                                                                   parallel: 4, deadline: 0.1)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.8
      expect(verdicts.values.map(&:reason).uniq).to eq(["unchecked: triage deadline"])
    end

    it "delivers unchecked at once the cards of a thread whose backend couldn't be made, with the error" do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      verdicts = described_class.judge_all("x", [card("a"), card("b"), card("c")], new_backend: ->(_) { raise KeyError, "no key" },
                                                                                   parallel: 2, deadline: 5)

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(verdicts.values.map(&:reason).uniq).to eq(["unchecked: triage failed (KeyError)"])
    end

    it "delivers unchecked a card whose backend raised" do
      backend = Object.new
      def backend.judge(_note, card) = card.id == "bad" ? raise("boom") : Samagotchi::Broadcast::Triage::Verdict.new(relevant: true, p: 1.0, reason: "model: yes", by: "model")

      verdicts = described_class.judge_all("x", [card("ok"), card("bad")], new_backend: ->(_) { backend }, parallel: 1)

      expect(verdicts.transform_values(&:reason)).to eq("ok" => "model: yes", "bad" => "unchecked: triage failed (RuntimeError)")
    end
  end
end
