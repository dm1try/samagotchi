# frozen_string_literal: true

require "fileutils"
require "stringio"
require "tmpdir"
require "support/fake_provider_server"
require "samagotchi/core_notice"

RSpec.describe Samagotchi::CoreNotice do
  let(:dir) { Dir.mktmpdir("core-notice") }
  let(:env) { { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state") } }
  let(:io) { StringIO.new }
  let(:line) { "chi: the core safety bundles (loop-guard, guardrails, cost-cap…) aren't installed: chi bundle install core" }

  after { FileUtils.rm_rf(dir) }

  def record(name)
    path = File.join(env.fetch("XDG_CONFIG_HOME"), "samagotchi", "memories", ".bundles", name, "manifest.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "{}")
  end

  it "prints once per state directory, even if core is later removed" do
    record("system")
    expect(described_class.show(env: env, io: io)).to eq(line)
    record("guardrails")
    FileUtils.rm_rf(File.join(env.fetch("XDG_CONFIG_HOME"), "samagotchi", "memories", ".bundles", "guardrails"))
    expect(described_class.show(env: env, io: io)).to be_nil
    expect(io.string).to eq("#{line}\n")
  end

  it "does not print or stamp when any core member has an install record" do
    %w[loop-guard check-in guardrails slow-commands agents-md cost-cap work-cap].each do |name|
      record(name)
      expect(described_class.show(env: env, io: io)).to be_nil
      FileUtils.rm_rf(File.join(env.fetch("XDG_CONFIG_HOME"), "samagotchi", "memories", ".bundles", name))
    end
    expect(described_class.show(env: env, io: io)).to eq(line)
  end

  it "stays quiet in a disabled test environment and inside a worker's tools" do
    expect(described_class.show(env: env.merge("SAMAGOTCHI_CORE_NOTICE" => "off"), io: io)).to be_nil
    expect(described_class.show(env: env.merge("SAMAGOTCHI_PROJECT_ENV" => "1"), io: io)).to be_nil
    expect(io.string).to eq("")
  end

  it "prints on stderr in a real one-shot without changing its answer on stdout" do
    FakeProviderServer.without_webmock do
      server = FakeProviderServer.start
      begin
        server.default("/v1/chat/completions", sse: FakeProviderServer.fixture("text_stream.sse"))
        config = File.join(env.fetch("XDG_CONFIG_HOME"), "samagotchi", "config.yml")
        FileUtils.mkdir_p(File.dirname(config))
        File.write(config, <<~YAML)
          default:
            model: fake
          hosts:
            main:
              url: #{server.base_url}
              api: openai
          recap: false
        YAML
        child_env = env.merge("HOME" => dir, "SAMAGOTCHI_CORE_NOTICE" => nil)
        out, err, status = run_chi("-p", "hello", "--non-interactive", env: child_env, chdir: dir, timeout: 30)
        expect(status.exitstatus).to eq(0)
        expect(out).not_to be_empty
        expect(out).not_to include(line)
        expect(err.lines.count { |entry| entry.chomp == line }).to eq(1)

        next_out, next_err, next_status = run_chi("-p", "hello", "--non-interactive", env: child_env, chdir: dir, timeout: 30)
        expect(next_status.exitstatus).to eq(0)
        expect(next_out).to eq(out)
        expect(next_err).not_to include(line)
      ensure
        server.stop
      end
    end
  end
end
