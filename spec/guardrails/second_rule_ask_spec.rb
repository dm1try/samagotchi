# frozen_string_literal: true

require "json"
require "tmpdir"
require "yaml"
require "samagotchi/guardrail_wiring"
require "samagotchi/guardrails"
require "samagotchi/system_one"

# Of two rules that ask about one call the first names the ask, so a stored
# rule grant is only ever checked against that rule. A second distinct rule's
# ask takes grants out: no rule-scope entry answers it and none is offered. An
# exact-call entry still does: it is keyed on the whole command the user saw.
RSpec.describe "A second rule's ask on one call" do
  let(:base) { File.realpath(Dir.mktmpdir("second-rule")) }
  let(:repo) { File.join(base, "repo").tap { |d| system("git", "init", "-q", d) } }
  let(:store) { Samagotchi::Guardrails::Approvals.new(dir: File.join(base, "guardrails")) }
  let(:shipped) do
    doc = YAML.safe_load_file(File.expand_path("../../lib/samagotchi/bundles/guardrails/guardrails/rules.yml", __dir__))
    Samagotchi::Guardrails::Rules.parse(doc["rules"], source: "bundle guardrails")
  end
  let(:merge_rule) do
    Samagotchi::Guardrails::Rules.parse([{ "id" => "git-merge", "tool" => "shell", "command" => '\bgit\s+merge(?=\s|$)',
                                           "verdict" => "ask", "reason" => "merges", "scopes" => %w[once rule] }],
                                        source: "bundle coordinator")
  end
  let(:rules) { Samagotchi::Guardrails::Rules.new(merge_rule + shipped) }
  let(:git) { Samagotchi::Guardrails::GitInfo.new }
  let(:context) { Samagotchi::Guardrails::Context.new(cwd: repo, session_id: "s1", git: git) }
  let(:asked) { [] }
  let(:gate) do
    Samagotchi::Guardrails::Gate.new(-> {}, context_lookup: -> { context }, approvals_lookup: -> { store }, checks_lookup: -> { [rules] },
                                     approver: lambda { |verdict|
                                       asked << verdict
                                       verdict.settle!(:deny, decided_by: "user", note: "no")
                                     })
  end

  after { FileUtils.rm_rf(base) }

  def evaluate(command) = gate.evaluate({ name: "execute", content: command }, iteration: 1, params: "")

  # Allow +rule+'s ask for +scope+, as the store would have it from the user.
  def grant(command, scope = "rule")
    verdict = evaluate(command)
    store.add(verdict, scope)
  end

  context "with the merge rule granted in this repo" do
    before { grant("git merge x") }

    it "passes a merge with no ask" do
      verdict = gate.settle_ask(evaluate("git merge y"))
      expect([verdict.decision, verdict.decided_by, verdict.scope, asked]).to eq([:allow, "approval", "rule", []])
    end

    it "passes two merges: the same rule, no second ask" do
      verdict = gate.settle_ask(evaluate("git merge y && git merge z"))
      expect([verdict.decision, verdict.decided_by, asked]).to eq([:allow, "approval", []])
    end

    {
      "git push" => "git merge y && git push",
      "git reset --hard" => "git merge y && git reset --hard",
      "rm -rf ~" => "git merge y && rm -rf ~"
    }.each do |what, command|
      it "asks about #{what} chained after it, once only, naming the first rule" do
        verdict = evaluate(command)
        expect([verdict.rule, verdict.scopes, verdict.second_rule_ask?, verdict.fresh_ask?]).to eq(["git-merge", %w[once], true, false])
        expect(gate.settle_ask(verdict)).to be_deny
        expect(asked).to eq([verdict])
      end
    end

    it "offers the card once only" do
      payload = Samagotchi::Guardrails::Approval.payload(evaluate("git merge y && git push"))
      expect(payload[:options]).to eq(["Allow once", "Deny"])
    end
  end

  it "closes the gap in existing rule pairs: a granted git-push doesn't cover the reset" do
    grant("git push")
    verdict = gate.settle_ask(evaluate("git push && git reset --hard"))
    expect([verdict.decision, asked.size]).to eq([:deny, 1])
  end

  describe "exact-call approvals on a second rule's ask" do
    let(:chain) { "git branch -D feat/x && git push origin --delete feat/x" }

    %w[repo session].each do |scope|
      it "takes a stored #{scope} entry for exactly this command as the answer" do
        store.add(evaluate(chain), scope)
        verdict = gate.settle_ask(evaluate(chain))
        expect([verdict.decision, verdict.decided_by, verdict.scope, asked]).to eq([:allow, "approval", scope, []])
      end

      it "doesn't take a #{scope} entry for another command" do
        store.add(evaluate(chain), scope)
        expect(gate.settle_ask(evaluate("#{chain} && echo more"))).to be_deny
        expect(asked.size).to eq(1)
      end
    end

    it "offers what both rules allow, minus the rule, and a wider answer is stored for the call" do
      verdict = evaluate(chain)
      expect(verdict.scopes).to eq(%w[once session repo])
      expect(Samagotchi::Guardrails::Approval.payload(verdict)[:options]).to eq(["Allow once", "Allow this call for the session", "Allow this call in this repo (repo)", "Deny"])
      store.add(verdict, "repo")
      expect(gate.settle_ask(evaluate(chain))).to be_allow
    end

    it "offers only what both allow: the merge rule's once and rule leave once" do
      expect(evaluate("git merge y && git push").scopes).to eq(%w[once])
    end

    it "narrows whichever rule comes first, and a third rule too" do
      expect(evaluate("git reset --hard && git push && git merge y").scopes).to eq(%w[once])
    end

    it "takes no stored rule grant of either rule, both granted or not" do
      grant("git branch -D feat/y")
      grant("git push")
      expect(gate.settle_ask(evaluate(chain))).to be_deny
      expect(asked.size).to eq(1)
    end
  end

  it "keeps a pair turn's fresh ask strict: no stored entry of any scope answers it" do
    verdict = evaluate("git push")
    store.add(verdict, "repo")
    store.add(verdict, "session")
    store.add(verdict, "rule")
    pair = evaluate("git push")
    pair.fresh_ask = true
    expect(gate.settle_ask(pair)).to be_deny
    expect(asked).to eq([pair])
  end

  it "leaves one rule's ask as it was: every scope, a grant answers" do
    verdict = evaluate("git push")
    expect([verdict.second_rule_ask?, verdict.scopes]).to eq([false, Samagotchi::Guardrails::Verdict::SCOPES])
  end

  it "counts a rule id once: a config copy of a bundle's rule is no second rule" do
    copy = Samagotchi::Guardrails::Rules.parse([{ "id" => "git-push", "tool" => "shell", "command" => "git push", "verdict" => "ask" }],
                                               source: "config")
    verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: "git push" })
    verdict.context = context
    verdict.targets = Samagotchi::Guardrails::Targets.for(verdict.call, context)
    Samagotchi::Guardrails::Rules.new(copy + shipped).check(verdict)
    expect([verdict.source, verdict.second_rule_ask?]).to eq(["config", false])
  end

  it "leaves a core ask's session answer alone: one rule after the child boundary isn't fresh" do
    verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: "git push" })
    verdict.ask!("outside", scopes: %w[once session], rule: "child-boundary", source: "core", decided_by: "core")
    verdict.context = context
    verdict.targets = Samagotchi::Guardrails::Targets.for(verdict.call, context)
    rules.check(verdict)
    expect([verdict.rule, verdict.scopes, verdict.second_rule_ask?]).to eq(["child-boundary", %w[once session], false])
  end

  it "keeps a deny a deny" do
    deny = Samagotchi::Guardrails::Rules.parse([{ "id" => "no-rm", "tool" => "shell", "command" => "rm ", "verdict" => "deny" }], source: "config")
    verdict = Samagotchi::Guardrails::Verdict.new(call: { name: "execute", content: "rm -rf ~ && git push" })
    verdict.context = context
    verdict.targets = Samagotchi::Guardrails::Targets.for(verdict.call, context)
    Samagotchi::Guardrails::Rules.new(deny + shipped).check(verdict)
    expect([verdict.decision, verdict.rule]).to eq([:deny, "no-rm"])
  end

  describe "System 1" do
    let(:s1) { Samagotchi::SystemOne }
    let(:session) { Samagotchi::Session.new_session(mode: "assist", model_name: "m", working_directory: repo) }
    let(:judge) { s1::FakeBackend.new { |_state, questions| questions.to_h { |q| [q.id, s1::Answer.new(id: q.id, type: :noul, noul: 0.99)] } } }
    let(:cards) { [] }
    let(:wiring) do
      client = s1::Client.new(backend: judge, mode: "on", host: "splash", model: "jev")
      Samagotchi::GuardrailWiring.new(scratch: false, hooks: -> {}, tools: -> {}, session: -> { session }, model_key: -> {},
                                      cancelled: -> { false }, ask: lambda { |payload|
                                        cards << payload
                                        nil
                                      }, system_one: -> { client }).tap do |w|
        w.state_dir = File.join(base, "sessions")
        w.interface = :worker
      end
    end
    let(:log) { s1::Log.new(dir: File.join(base, "guardrails")) }

    before do
      allow(Samagotchi::Config).to receive(:get).and_call_original
      allow(Samagotchi::Config).to receive(:get).with("guardrails.system_one.rules").and_return("git-merge")
      5.times do |i|
        id = log.judgment(rule: "git-merge", tool: "execute", p: 0.99, decision: "asked", origin: "live", call_digest: "d#{i}")
        log.label(id, "allow_once")
      end
    end

    it "auto-allows the rule's own ask, with its record clean" do
      verdict = wiring.request_approval(evaluate("git merge y"))
      expect([verdict.decision, verdict.decided_by, cards]).to eq([:allow, "system one", []])
    end

    it "never auto-allows a second rule's ask: the card opens, and the judgment says it was asked" do
      verdict = wiring.request_approval(evaluate("git merge y && git push"))
      expect(verdict).to be_deny
      expect(cards.size).to eq(1)
      expect(log.entries.last).to include("rule" => "git-merge", "decision" => "asked", "p" => 0.99)
    end
  end
end
