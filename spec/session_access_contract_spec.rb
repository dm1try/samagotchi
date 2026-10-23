# frozen_string_literal: true

require "spec_helper"
require "samagotchi/session_access"
require "samagotchi/session_access/contract"
require "samagotchi/send_command"
require "samagotchi/answer_command"
require "samagotchi/note_command"
require "samagotchi/context_command"
require "samagotchi/sessions_command"
require "samagotchi/session_delete_command"
require "samagotchi/share_command"
require "samagotchi/run_options"

# Every session command, subcommand and flag says whether it runs against a
# remote (supported) or on this machine only (local_only): a new one fails
# here until the table says which.
RSpec.describe Samagotchi::SessionAccess::Contract do
  contract = described_class
  values = [contract::SUPPORTED, contract::LOCAL_ONLY]

  # bin/chi's SUBCOMMANDS keys, read from the script (it runs on load).
  chi_subcommands = File.read(File.expand_path("../bin/chi", __dir__))[/^SUBCOMMANDS = \{.*?^\}\.freeze/m]
                        .scan(/^\s+"([a-z-]+)" => \[/).flatten

  # Each session command's (or subcommand's) flags; nil: it takes none.
  flags_of = {
    "send" => Samagotchi::SendCommand::FLAGS,
    "answer" => Samagotchi::AnswerCommand::FLAGS,
    "note" => Samagotchi::NoteCommand::FLAGS,
    **Samagotchi::ContextCommand::SUBCOMMANDS.to_h { |sub| ["context #{sub}", Samagotchi::ContextCommand::FLAGS.fetch(sub)] },
    **Samagotchi::SessionsCommand::SUBCOMMANDS.to_h { |sub| ["sessions #{sub}", Samagotchi::SessionsCommand::FLAGS[sub]] },
    "sessions delete" => Samagotchi::SessionDeleteCommand::FLAGS,
    "share" => Samagotchi::ShareCommand::FLAGS,
    **Samagotchi::ShareCommand::SUBCOMMANDS.to_h { |sub| ["share #{sub}", Samagotchi::ShareCommand::SUB_FLAGS.fetch(sub)] }
  }
  subcommands_of = { "context" => Samagotchi::ContextCommand::SUBCOMMANDS,
                     "sessions" => Samagotchi::SessionsCommand::SUBCOMMANDS,
                     "share" => Samagotchi::ShareCommand::SUBCOMMANDS }

  it "reads bin/chi's subcommands" do
    expect(chi_subcommands).to include("send", "sessions", "bundle")
  end

  it "has every bin/chi subcommand in the table or MACHINE, not both" do
    chi_subcommands.each do |command|
      listed = values.include?(contract.status(command))
      expect(listed ^ contract::MACHINE.include?(command)).to be(true), "#{command}: in the table or MACHINE, one of them"
    end
  end

  it "has every subcommand of a supported command in the table" do
    subcommands_of.each do |command, subs|
      next unless contract.status(command) == contract::SUPPORTED

      subs.each do |sub|
        expect(values).to include(contract.status(command, sub)), "chi #{command} #{sub}: supported or local_only?"
      end
    end
  end

  it "has every flag of a supported command or subcommand in the table, by one of its names" do
    flags_of.each do |words, flags|
      next unless contract.supported?(*words.split)

      Array(flags&.names).each do |names|
        statuses = names.filter_map { |name| contract.status(*words.split, name) }
        expect(statuses.size).to eq(1), "chi #{words} #{names.join("/")}: supported or local_only? (one entry)"
        expect(values).to include(statuses.first)
      end
    end
  end

  it "lists nothing that isn't there: no unknown command, subcommand or flag, no flags under a local_only one" do
    contract::TABLE.each do |key, status|
      expect(values).to include(status), key
      words = key.split
      expect(chi_subcommands).to include(words.first), key
      flag = words.last.start_with?("-") ? words.pop : nil
      if words.size == 2
        expect(subcommands_of.fetch(words.first)).to include(words.last), key
      end
      next unless flag

      expect(contract.status(*words)).to eq(contract::SUPPORTED), "#{key}: a local_only command lists no flags"
      expect(Array(flags_of[words.join(" ")]&.names).flatten).to include(flag), "#{key}: no such flag"
    end
  end

  # bin/chi's run flags (a session in this terminal; under a remote, a
  # remote attach): each one is a remote attach's, or this machine's.
  it "classifies every run flag: listed in RUN, or a config registry flag (this machine's config)" do
    unclassified = Samagotchi::RunOptions.switches.reject { |flag| values.include?(contract.run_status(flag)) }
    expect(unclassified).to eq([])
    listed = contract::RUN.values.flatten
    expect(listed - Samagotchi::RunOptions.switches).to eq([]), "RUN lists a flag the parser doesn't take"
    expect(listed.tally.select { |_flag, n| n > 1 }.keys).to eq([]), "a flag in both lists"
    expect(contract.run_status("--recap-base-url")).to eq(contract::LOCAL_ONLY)
    expect(contract.run_status("--attach")).to eq(contract::SUPPORTED)
  end

  it "answers for a whole command line" do
    expect(contract.supported?("send", "--wait")).to be(true)
    expect(contract.supported?("context", "add", "--cmd")).to be(true)
    expect(contract.supported?("context", "add", "--project")).to be(false)
    expect(contract.supported?("context", "refresh")).to be(false)
    expect(contract.supported?("sessions", "stats")).to be(false)
    expect(contract.supported?("broadcast")).to be(false)
    expect(contract.status("bundle")).to be_nil
  end
end
