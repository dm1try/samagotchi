# frozen_string_literal: true

require "stringio"
require "samagotchi/run_options"

# RunOptions.parse: bin/chi's run flags (the bin/chi CLI specs run the whole
# command; these pin the parse itself).
RSpec.describe Samagotchi::RunOptions do
  def parse(*argv)
    args = argv.dup
    options, overrides = described_class.parse(args)
    [options, overrides, args]
  end

  # What the parse said on stderr and its exit status.
  def refusal(*argv)
    err = StringIO.new
    $stderr = err
    described_class.parse(argv.dup)
    raise "no exit"
  rescue SystemExit => e
    [err.string, e.status]
  ensure
    $stderr = STDERR
  end

  it "parses the session flags, leaving the rest in argv" do
    options, overrides, rest = parse("-p", "hi", "--attach", "ab12", "--model", "m1", "--memory", "a,b", "--memory", "c",
                                     "--tool", "x", "--no-tool", "y", "--no-tool=z", "--set", "recap.enabled=false",
                                     "--llm-context", "stale", "--no-interrupt", "web")

    expect(options).to include(prompt: "hi", attach: "ab12", model: "m1", memories: %w[a,b c], tools: ["x"],
                               no_tools: %w[y z], sets: ["recap.enabled=false"], llm_context: { strategy: "stale" },
                               no_interrupt: true)
    expect(overrides).to include("default.model" => "m1", "no_interrupt" => true)
    expect(rest).to eq(["web"])
  end

  it "starts from this machine's no_interrupt and no_default_input, with the web flags off" do
    options, overrides, = parse
    expect(options).to eq(verbose: false, no_interrupt: Samagotchi::Config.get("no_interrupt"), non_interactive: false,
                          no_default_input: Samagotchi::Config.get("no_default_input"), web: false, web_port: nil,
                          web_open: false, web_markdown: nil, flags: [])
    expect(overrides).to eq({})
  end

  it "takes chi web's start folder as --start-dir, never a generated --web-start-dir" do
    options, overrides, rest = parse("web", "--start-dir", "~/proj")
    expect([options[:start_dir], overrides, rest]).to eq(["~/proj", {}, ["web"]])
    expect(refusal("--web-start-dir", "x")).to eq(["Error: invalid option: --web-start-dir (see chi --help)\n", 1])
  end

  describe ".web_restart_argv" do
    let(:argv) do
      ["web", "--port=4600", "--open", "--model", "m1", "--model-profile", "gemma4", "--no-interrupt",
       "--recap-sentences", "2-3", "--session-idle-exit-minutes", "5", "--no-web-working-set", "--web-markdown",
       "--new-token", "--tunnel", "tailscale", "--scope", "all", "--thinking", "low", "--start-dir", "/tmp/p", "-v",
       "--web-host=lan", "--no-tool", "execute"]
    end

    it "rebuilds every flag chi web was started with, as parsed, but --open and --new-token" do
      options, = parse(*argv)

      expect(described_class.web_restart_argv(options)).to eq([
        "web", "--no-tool", "execute", "--port", "4600", "--model", "m1", "--model-profile", "gemma4", "--no-interrupt",
        "--recap-sentences", "2-3", "--session-idle-exit-minutes", "5", "--no-web-working-set", "--web-markdown",
        "--tunnel", "tailscale", "--scope", "all", "--thinking", "low", "--start-dir", "/tmp/p", "--verbose",
        "--web-host", "lan"
      ])
    end

    # The shape that can't drift from the parser: what the restart parses to is what the first start did.
    it "parses back to the same options and config overrides, the one-shot flags aside" do
      options, overrides, rest = parse(*argv)
      again, overrides_again, rest_again = parse(*described_class.web_restart_argv(options))

      expect(overrides_again).to eq(overrides)
      expect(rest_again).to eq(rest)
      expect(again.except(:web_open, :new_token, :flags)).to eq(options.except(:web_open, :new_token, :flags))
      expect(again).to include(web_open: false)
      expect(again).not_to have_key(:new_token)
    end

    it "is just web for a bare chi web; an abbreviation never gets as far as the record" do
      options, = parse("web")
      expect(described_class.web_restart_argv(options)).to eq(["web"])
      expect(refusal("web", "--ope")).to eq(["Error: invalid option: --ope (see chi --help)\n", 1])
    end
  end

  it "keeps a prompt that looks like --no-tool as the prompt" do
    options, = parse("-p", "--no-tool=x is broken")
    expect(options[:prompt]).to eq("--no-tool=x is broken")
    expect(options[:no_tools]).to be_nil
  end

  it "refuses an underscored flag, a flag where the prompt goes, a bare --no-tool and an unknown option" do
    expect(refusal("--no_interrupt")).to eq(["Unknown option: --no_interrupt (did you mean --no-interrupt?)\n", 1])
    expect(refusal("-p", "--model")).to eq(["Error: -p needs the prompt text right after it (got the flag --model) " \
                                            "(see chi --help)\n", 2])
    expect(refusal("--no-tool", "--model")).to eq(["Error: missing argument: --no-tool (see chi --help)\n", 1])
    expect(refusal("--bogus")).to eq(["Error: invalid option: --bogus (see chi --help)\n", 1])
  end

  it "takes a flag's whole name only: an abbreviation is an unknown option (a remote can't read it past its contract)" do
    { %w[--verb] => "--verb", %w[--mem x] => "--mem", %w[--non-inter] => "--non-inter", %w[--append x] => "--append",
      %w[--no-share] => "--no-share", %w[--att ab] => "--att" }.each do |argv, flag|
      expect(refusal(*argv)).to eq(["Error: invalid option: #{flag} (see chi --help)\n", 1]), argv.join(" ")
    end
    options, = parse("--verbose", "--memory", "x", "--no-shared", "-v")
    expect(options).to include(verbose: true, memories: ["x"], shared: false)
  end

  describe ".switches" do
    it "lists every switch the parser takes, long and short, --no-tool too" do
      expect(described_class.switches).to include("-p", "--prompt", "--attach", "--resume", "--shared", "--no-shared",
                                                  "--model", "--thinking", "--toolkit", "--tool", "--no-tool", "--set",
                                                  "--parent-answers", "--memory", "--mute", "--append-system-prompt",
                                                  "--llm-context", "--llm-context-apply", "--llm-context-budget",
                                                  "--no-interrupt", "--non-interactive", "-v", "--verbose",
                                                  "--no-default-input", "--port", "--open", "--new-token", "--scope",
                                                  "--profile", "--version", "-h", "--help", "--web-markdown",
                                                  "--no-web-markdown")
      # The registry's own flags; default.model is --model and web.port --port.
      registry = Samagotchi::Config.cli_entries.reject { |entry| %w[default.model web.port].include?(entry.key) }
      expect(described_class.switches).to include(*registry.map(&:cli_flag))
    end

    it "covers every flag an underscored spelling is refused for" do
      expect(described_class::KNOWN - described_class.switches).to eq([])
    end
  end
end
