# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "pathname"
require "samagotchi/testing"
require "samagotchi/testing/boundary"

# Each shipped bundle reaches chi only through the "Stable for bundles"
# list (Testing::Boundary::ALLOWED), but for its listed exceptions: a new
# internal reference fails, and so does a stale exception.
RSpec.describe Samagotchi::Testing::Boundary do
  bundles = Dir[File.join(Samagotchi::Testing::Bundle::SHIPPED_DIR, "*", "manifest.yml")].map { |path| File.dirname(path) }.sort

  # An exception whose why starts "spec:" excuses the bundle's specs only
  # (files under its spec/); the others excuse any of its files.
  bundles.each do |dir|
    name = File.basename(dir)
    it "#{name} reaches only the stable names, and its listed exceptions, file by file" do
      exceptions = described_class::EXCEPTIONS.fetch(name, {})
      spec_only = exceptions.select { |_, why| why.start_with?("spec:") }.keys
      findings = described_class.scan(dir)
      in_spec, in_code = findings.partition { |finding| finding.file.start_with?("spec/") }

      expect(in_code.reject { |f| (exceptions.keys - spec_only).include?(f.reference) }.map(&:to_h)).to eq([])
      expect(in_spec.reject { |f| exceptions.key?(f.reference) }.map(&:to_h)).to eq([])
      expect(exceptions.keys - spec_only - in_code.map(&:reference)).to eq([]), "stale (no code uses it)"
      expect(spec_only - in_spec.map(&:reference)).to eq([]), "stale (no spec uses it)"
    end
  end

  it "lists exceptions only for shipped bundles, each with why" do
    expect(described_class::EXCEPTIONS.keys - bundles.map { |dir| File.basename(dir) }).to eq([])
    expect(described_class::EXCEPTIONS.values.flat_map(&:values)).to all(match(/\S/))
  end

  describe ".scan" do
    let(:dir) { Dir.mktmpdir("boundary-") }

    after { FileUtils.rm_rf(dir) }

    it "finds internal names and requires in every .rb of the bundle, once per file, and passes the stable ones" do
      FileUtils.mkdir_p(File.join(dir, "hooks"))
      FileUtils.mkdir_p(File.join(dir, "spec"))
      relative = Pathname.new(File.join(Dir.pwd, "lib/samagotchi/engine")).relative_path_from(Pathname.new(dir)).to_s
      File.write(File.join(dir, "plugin.rb"), <<~RUBY)
        require "samagotchi/plugin/peer"
        require "samagotchi/engine"
        require_relative "#{relative}"
        require_relative "local"
        class Plugin < Samagotchi::Plugin::Peer
          def a = Samagotchi::Engine.new
          def b = Samagotchi::Engine.new
          def c = [Samagotchi::Config.get("x"), Samagotchi::Config.validate_yaml_sections, Samagotchi::VERSION]
          def d = [Samagotchi::Tools::Execute::NAME, Samagotchi::Tools::Execute.const_get(:X), Samagotchi::Plugin::Api.tool_spec]
        end
      RUBY
      File.write(File.join(dir, "hooks", "h.rb"), "class H; def call(e) = Samagotchi::Log.error(:x, 'y'); end\n")
      File.write(File.join(dir, "spec", "x_spec.rb"), %(require "samagotchi/testing/rspec"\nSamagotchi::Testing::Bundle\n))

      expect(described_class.scan(dir).map { |finding| [finding.file, finding.reference] }).to eq(
        [["hooks/h.rb", "Samagotchi::Log.error"],
         ["plugin.rb", "Samagotchi::Engine.new"], ["plugin.rb", "Samagotchi::Config.validate_yaml_sections"],
         ["plugin.rb", "Samagotchi::Tools::Execute.const_get"], ["plugin.rb", 'require "samagotchi/engine"'],
         ["plugin.rb", %(require_relative "#{relative}")]]
      )
    end
  end

  describe ".gone?" do
    let(:dir) { Dir.mktmpdir("boundary-gone-") }

    after { FileUtils.rm_rf(dir) }

    # lib/samagotchi loads lazily, so what a process has required says nothing
    # about what chi has. A probe in this process would have most of lib
    # loaded already; the question only bites in a fresh Ruby that knows
    # nothing but the boundary module.
    def probe(references)
      script = File.join(dir, "probe.rb")
      File.write(script, <<~RUBY)
        require "json"
        $LOAD_PATH.unshift(ARGV[0])
        require "samagotchi/testing/boundary"
        boundary = Samagotchi::Testing::Boundary
        puts JSON.generate(gone: ARGV[1..].select { |reference| boundary.gone?(reference) })
      RUBY
      reader, writer = IO.pipe
      pid = Process.spawn(RbConfig.ruby, script, described_class::LIB_DIR, *references, out: writer)
      writer.close
      answer = reader.read
      reader.close
      Process.wait(pid)
      JSON.parse(answer)
    end

    it "finds none of the exceptions a shipped bundle reaches gone: every name still resolves" do
      references = described_class::EXCEPTIONS.flat_map { |_, listed| listed.keys }.uniq
      expect(probe(references)["gone"]).to eq([])
    end

    it "doesn't call a bare require of chi gone" do
      expect(probe([%(require "samagotchi")])["gone"]).to eq([])
    end

    it "survives a file of chi's that can't load (a gem missing), and won't call a name it defines gone" do
      file = File.join(dir, "needs_a_gem.rb")
      File.write(file, %(require "no_such_gem_at_all"\nmodule Samagotchi; module OnlyThere; end; end\n))
      script = File.join(dir, "probe_load.rb")
      File.write(script, <<~RUBY)
        $LOAD_PATH.unshift(ARGV[0])
        require "samagotchi/testing/boundary"
        boundary = Samagotchi::Testing::Boundary
        boundary.send(:remove_const, :CORE_FILES)
        boundary.const_set(:CORE_FILES, [ARGV[1]].freeze)
        print [boundary.gone?("Samagotchi::OnlyThere"), boundary.gone?("Samagotchi::NoSuchThing")].inspect
      RUBY
      output = IO.popen([RbConfig.ruby, script, described_class::LIB_DIR, file], &:read)
      expect(output).to eq("[false, true]")
    end

    it "calls a name this chi does not have gone, and one it does not" do
      result = probe(["Samagotchi::OldInternal::Thing", "Samagotchi::Log", "Samagotchi::Log.warn",
                      "Samagotchi::Log.no_such_method", %(require "samagotchi/engine"),
                      %(require "samagotchi/no_such_file")])
      expect(result["gone"]).to eq(["Samagotchi::OldInternal::Thing", "Samagotchi::Log.no_such_method",
                                    %(require "samagotchi/no_such_file")])
    end
  end
end
