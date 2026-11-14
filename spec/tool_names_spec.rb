# frozen_string_literal: true

require "spec_helper"
require "open3"
require "samagotchi/tool_names"
require "samagotchi/tools/builtins"
require "samagotchi/tool_activity"

RSpec.describe Samagotchi::ToolNames do
  # Each built-in's class, by its constant's name under Tools (a tool class's
  # own .name is its tool name).
  def builtins
    classes = Samagotchi::Tools::Builtins::CLASSES + Samagotchi::Tools::Builtins::LAYER_CLASSES
    classes.to_h { |klass| [Samagotchi::Tools.constants.find { |c| Samagotchi::Tools.const_get(c).equal?(klass) }, klass] }
  end

  # The table's per-tool modules (the ones with a NAME).
  def tools
    described_class.constants.select do |c|
      table = described_class.const_get(c)
      table.instance_of?(Module) && table.const_defined?(:NAME, false)
    end
  end

  it "has a module for every built-in, and no other" do
    expect(tools.sort).to eq(builtins.keys.sort)
    expect(described_class::NAMES).to eq(tools.map { |c| described_class.const_get(c)::NAME })
  end

  it "names each built-in as its class and its declaration do" do
    declared = Samagotchi::Tools::Builtins.default.registered.map(&:name)

    builtins.each do |const, klass|
      expect(klass::NAME).to equal(described_class.const_get(const)::NAME), "#{const}::NAME is not the table's"
    end
    expect(described_class::NAMES).to match_array(declared)
  end

  it "keeps every value of the table a constant of its tool class too, the same object" do
    builtins.each do |const, klass|
      table = described_class.const_get(const)
      table.constants.each do |name|
        expect(klass.const_defined?(name, false)).to be(true), "#{klass}::#{name} is missing"
        expect(klass.const_get(name, false)).to equal(table.const_get(name)), "#{klass}::#{name} is not the table's"
      end
    end
  end

  describe "BuiltinRegistry" do
    let(:light) { described_class::BuiltinRegistry }
    let(:default) { Samagotchi::Tools::Builtins.default }

    it "answers what a display asks a registry's entry as Tools::Builtins.default does" do
      described_class::NAMES.each do |name|
        [name, name.to_sym].each do |key|
          entry = light[key]
          real = default[key]
          expect([entry.name, entry.core?, entry.source, entry.label, entry.preview])
            .to eq([real.name, real.core?, real.source, real.label, real.preview]), name
          expect(light.key?(key)).to eq(default.key?(key))
        end
      end
    end

    it "gives ToolActivity's rows as Tools::Builtins.default does, a call with args: too (no registry differs)" do
      described_class::NAMES.each do |name|
        call = { name: name, content: "x", args: { "when" => "5m" } }
        row = ->(registry) { Samagotchi::ToolActivity.tool_activity_event(name, call, "ok", registry: registry) }

        expect(row.call(light)).to eq(row.call(default)), name
      end
      call = { name: "register_reminder", args: { "when" => "5m" } }
      expect(Samagotchi::ToolActivity.tool_activity_params("register_reminder", call, registry: light)).to be_nil
      expect(Samagotchi::ToolActivity.tool_activity_params("register_reminder", call, registry: nil)).to eq('when="5m"')
    end

    it "knows no other tool" do
      %w[call_tool tool_search chrome_screenshot Execute].each do |name|
        expect(light[name]).to be_nil
        expect(light.key?(name)).to be(false)
        expect(default[name]).to be_nil
      end
    end
  end

  it "loads with no other file" do
    lib = File.expand_path("../lib", __dir__)
    script = 'before = $LOADED_FEATURES.dup; require "samagotchi/tool_names"; puts $LOADED_FEATURES - before'
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)

    expect(status).to be_success, err
    expect(out.lines(chomp: true).map { |f| File.basename(f) }).to eq(["tool_names.rb"])
  end
end
