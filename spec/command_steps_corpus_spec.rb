# frozen_string_literal: true

require "json"
require "spec_helper"
require "samagotchi/command_steps"

# CommandSteps over real execute commands (spec/fixtures/command_steps:
# 58 commands from saved sessions, paths anonymized to /p).
RSpec.describe Samagotchi::CommandSteps, "on the corpus" do
  corpus = JSON.parse(File.read(File.expand_path("fixtures/command_steps/corpus.json", __dir__)))

  def parse(text) = described_class.parse(text)&.to_h

  # The command in the corpus starting with +prefix+ (one only).
  define_method(:command) do |prefix|
    found = corpus.select { |text| text.start_with?(prefix) }
    raise "#{found.size} corpus commands start with #{prefix.inspect}" unless found.size == 1

    found.first
  end

  it "falls back on at most 10% of the commands" do
    fallbacks = corpus.count { |text| described_class.parse(text).nil? }

    expect(fallbacks.fdiv(corpus.size)).to be <= 0.10
  end

  it "takes each step's text from the command (a heredoc's step up to its body)" do
    corpus.each do |text|
      described_class.parse(text)&.steps&.each do |step|
        expect(text).to include(step.heredoc ? step.text[/\A.*?<<-?['"]?\w+['"]?/] : step.text)
      end
    end
  end

  {
    "cd /p/projects/samagotchi && git log --oneline --all" =>
      { cd: "/p/projects/samagotchi",
        steps: [{ text: "git log --oneline --all --grep='question_card\\|QuestionCard\\|ask_user_question' 2>/dev/null",
                  limit: "head 30" }] },
    "cd ../samagotchi-source-links && rg -n \"shipped_bundle_dir\"" =>
      { cd: "../samagotchi-source-links",
        steps: [{ text: "rg -n \"shipped_bundle_dir\" -B 5 -A 15 lib/samagotchi/commands/bundle.rb 2>/dev/null" },
                { text: "rg -rln \"shipped_bundle_dir\" lib/", op: "||" }] },
    "rg -n \"def bundle_settings\"" =>
      { steps: [{ text: "rg -n \"def bundle_settings\" -A 15 lib/samagotchi/engine.rb", limit: "head 25" },
                { text: "rg -n \"bundles\" bin/chi", op: ";", limit: "head 20" }] },
    "cd ../samagotchi-source-links && sed -n '238,270p'" =>
      { cd: "../samagotchi-source-links",
        steps: [{ text: "sed -n '238,270p' lib/samagotchi/hooks/registry.rb" },
                { text: "sed -n '1,60p' spec/hooks/runtime_spec.rb", op: "&&", label: "runtime_spec" }] },
    "cd harness && echo" =>
      { cd: "harness",
        steps: [{ text: "cat Gemfile", label: "Gemfile" }, { text: "cat bin/agent", op: "&&", label: "bin/agent" },
                { text: "cat bin/agent-tui", op: "&&", label: "bin/agent-tui" }] },
    "sleep 2 && echo \"=== fake status ===\"" =>
      { steps: [{ text: "sleep 2" }, { text: "cat /tmp/fake_status.txt 2>/dev/null", op: "&&", label: "fake status" },
                { text: "lsof -nP -iTCP:47381 2>/dev/null", op: ";" }, { text: "echo \"FAKE LISTENING\"", op: "&&" },
                { text: "echo \"FAKE DOWN\"", op: "||" },
                { text: "curl -s http://127.0.0.1:47381/v1/models", op: ";", label: "/v1/models via fake" }] },
    "cd /p/projects/samagotchi-web-answer-path && bundle exec parallel_rspec" =>
      { cd: "/p/projects/samagotchi-web-answer-path",
        steps: [{ text: "bundle exec parallel_rspec -n 8 </dev/null 2>&1", limit: "tail 3" }] },
    "cd /p/projects/samagotchi && node --test" =>
      { cd: "/p/projects/samagotchi",
        steps: [{ text: "node --test spec/web/public/question_card.test.js 2>&1" },
                { text: "grep -E \"^✔|^ℹ (tests|pass|fail)\"", op: "|" }] },
    "cd /p/projects/samagotchi-ticker && git commit" =>
      { cd: "/p/projects/samagotchi-ticker",
        steps: [{ text: "git commit -m \"$(cat <<'EOF')\"", heredoc: { tag: "EOF", lines: 11 } },
                { text: "git log --oneline -1", op: "&&" }] },
    "cd /p/projects/shop_app && git commit" =>
      { cd: "/p/projects/shop_app",
        steps: [{ text: "git commit -m \"$(cat <<'EOF')\"", heredoc: { tag: "EOF", lines: 9 } }] },
    "cat > /tmp/run_t6.sh" =>
      { steps: [{ text: "cat > /tmp/run_t6.sh <<'EOF'", heredoc: { tag: "EOF", lines: 3 } },
                { text: "chmod +x /tmp/run_t6.sh", op: "\n" }, { text: "echo ready", op: "&&" }] },
    "mkdir -p /tmp/sl-smoke" =>
      { steps: [{ text: "mkdir -p /tmp/sl-smoke" }, { text: "cd /tmp/sl-smoke", op: "&&" },
                { text: "cat > script.json <<'JSON'", op: "&&", heredoc: { tag: "JSON", lines: 9 } },
                { text: "echo script > mode", op: "\n" }, { text: "ls -la", op: "&&" }] },
    "cd /p/projects/samagotchi-provider-probing && nohup" =>
      { cd: "/p/projects/samagotchi-provider-probing",
        steps: [{ text: "nohup env PP_LOG=/tmp/pp/fake.log PP_PORT=47823 bundle exec ruby /tmp/pp/fake_native.rb " \
                        "> /tmp/pp/fake.out 2>&1" },
                { text: "sleep 3", op: "&" },
                { text: "curl -s -m 2 \"http://127.0.0.1:47823/props?model=x\"", op: ";", limit: "head -c 60" },
                { text: "cat /tmp/pp/fake.out", op: ";", limit: "tail 5" }] },
    "cd /p/projects/shop_app && for f in" => nil,
    "cd ~/.local/state/samagotchi/sessions && for f in" => nil
  }.each do |prefix, expected|
    it "parses #{prefix.inspect}" do
      expect(parse(command(prefix))).to eq(expected)
    end
  end

  it "keeps an inline script one step, its lines in its text" do
    parsed = parse(command("cd ../samagotchi-source-links && ruby -e '\nRegexp.timeout"))

    expect(parsed[:cd]).to eq("../samagotchi-source-links")
    expect(parsed[:steps].size).to eq(1)
    expect(parsed[:steps][0][:text]).to start_with("ruby -e '\nRegexp.timeout = 0.001\n").and end_with("'")
  end
end
