# frozen_string_literal: true

require "tmpdir"
require "samagotchi/system_prompt"

RSpec.describe Samagotchi::SystemPrompt do
  subject(:prompt) do
    described_class.new(profile: -> {}, tools: -> { [] }, session: -> {}, thinking: -> {})
  end

  around do |example|
    saved = ENV["PATH"]
    Dir.mktmpdir do |bin|
      @bin = bin
      example.run
    ensure
      ENV["PATH"] = saved
    end
  end

  def rg_available? = prompt.send(:rg_available?)

  # A PATH with no `command` program on it, as on Linux (macOS ships
  # /usr/bin/command): the check must not depend on a shell builtin.
  it "finds rg on PATH without a shell" do
    File.write(File.join(@bin, "rg"), "#!/bin/sh\n")
    File.chmod(0o755, File.join(@bin, "rg"))
    ENV["PATH"] = @bin
    expect(rg_available?).to be(true)
  end

  it "doesn't find rg when no PATH folder has it" do
    ENV["PATH"] = @bin
    expect(rg_available?).to be(false)
  end
end
