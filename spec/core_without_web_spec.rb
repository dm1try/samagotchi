# frozen_string_literal: true

require "open3"
require "rbconfig"

# The core files a session runs on never load chi web (lib/samagotchi/web/):
# participants' domain (Grants, Redact, ParticipantExposure, PrivateFiles)
# lives next to them. A fresh Ruby, so what this suite already loaded can't
# hide a require.
RSpec.describe "core files without chi web" do
  core = %w[engine worker participants objectives_check session_participants participants_watch grants redact].freeze

  it "loads #{core.join(", ")} with no file under lib/samagotchi/web/ and no Samagotchi::Web" do
    lib = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      ARGV.each { |name| require "samagotchi/\#{name}" }
      web = File.join(#{lib.inspect}, "samagotchi", "web", "")
      puts $LOADED_FEATURES.select { |path| path.start_with?(web) }
      puts "Samagotchi::Web defined" if defined?(Samagotchi::Web)
    RUBY
    out, err, status = Open3.capture3(RbConfig.ruby, "-I", lib, "-e", script, *core, stdin_data: "")
    expect(status).to be_success, err
    expect(out).to eq("")
  end
end
