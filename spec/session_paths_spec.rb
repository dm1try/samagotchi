# frozen_string_literal: true

require "open3"
require "rbconfig"
require "spec_helper"
require "samagotchi/session_paths"
require "samagotchi/session"

# SessionPaths: a session's files and the id rule, a leaf Session extends.
# The refusals of every id from outside are in spec/session_id_check_spec.rb.
RSpec.describe Samagotchi::SessionPaths do
  let(:state_dir) { "/state/samagotchi/sessions" }

  it "names a session's dir and <id>.json under the sessions dir" do
    expect(described_class.session_dir("abc-1", state_dir: state_dir)).to eq("/state/samagotchi/sessions/abc-1")
    expect(described_class.session_file("abc-1", state_dir: state_dir)).to eq("/state/samagotchi/sessions/abc-1.json")
  end

  it "takes ids of letters, digits, - and _ (not starting with -, up to 128) and refuses the rest" do
    expect(%w[s1 sess_1-a _x].map { |id| described_class.valid_id?(id) }).to all(be(true))
    expect(["-x", "a/b", "..", "", "a" * 129, nil, 42].map { |id| described_class.valid_id?(id) }).to all(be(false))
    expect(described_class.check_id!("s1")).to eq("s1")
    expect { described_class.check_id!("../x") }
      .to raise_error(described_class::InvalidId, 'invalid session id: "../x"')
    expect { described_class.session_dir("a/b", state_dir: state_dir) }.to raise_error(described_class::InvalidId)
  end

  it "puts the sessions dir under the XDG state home" do
    expect(described_class.default_state_dir(env: { "XDG_STATE_HOME" => "/xdg" }))
      .to eq(File.join("/xdg", described_class::STATE_SUBDIR))
  end

  it "answers the same through Session, its methods public there" do
    %i[session_dir session_file default_state_dir valid_id? check_id!].each do |name|
      expect(Samagotchi::Session.public_methods).to include(name)
    end
    expect(Samagotchi::Session.session_file("s1", state_dir: state_dir))
      .to eq(described_class.session_file("s1", state_dir: state_dir))
    expect(Samagotchi::Session.default_state_dir).to eq(described_class.default_state_dir)
  end

  it "loads alone, without Session" do
    lib = File.expand_path("../lib", __dir__)
    script = 'require "samagotchi/session_paths"; abort "session" if defined?(Samagotchi::Session)'
    _out, err, status = Open3.capture3(RbConfig.ruby, "-w", "-I", lib, "-e", script)
    expect(status).to be_success, err
  end
end
