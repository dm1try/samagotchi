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
end
