# frozen_string_literal: true

require "spec_helper"
require "open3"
require "samagotchi/tool_names"
require "samagotchi/tools/builtins"

RSpec.describe Samagotchi::ToolNames do
  # Each built-in's class, by its constant's name under Tools (a tool class's
  # own .name is its tool name).
  def builtins
    classes = Samagotchi::Tools::Builtins::CLASSES + Samagotchi::Tools::Builtins::LAYER_CLASSES
    classes.to_h { |klass| [Samagotchi::Tools.constants.find { |c| Samagotchi::Tools.const_get(c).equal?(klass) }, klass] }
  end

  it "has a module for every built-in, and no other" do
    expect(described_class.constants.sort).to eq(builtins.keys.sort)
  end

  it "names each built-in as its class and its declaration do" do
    declared = Samagotchi::Tools::Builtins.default.registered.map(&:name)

    builtins.each do |const, klass|
      expect(klass::NAME).to equal(described_class.const_get(const)::NAME), "#{const}::NAME is not the table's"
    end
    expect(described_class.constants.map { |c| described_class.const_get(c)::NAME }).to match_array(declared)
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

  it "loads with no other file" do
    lib = File.expand_path("../lib", __dir__)
    script = 'before = $LOADED_FEATURES.dup; require "samagotchi/tool_names"; puts $LOADED_FEATURES - before'
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script)

    expect(status).to be_success, err
    expect(out.lines(chomp: true).map { |f| File.basename(f) }).to eq(["tool_names.rb"])
  end
end
