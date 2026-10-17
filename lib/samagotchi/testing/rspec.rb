# frozen_string_literal: true

require "rspec/core"
require_relative "../testing"

# The bundle test kit in RSpec (EXPERIMENTAL, docs/plugins.md): example groups
# tagged :bundle get Samagotchi::Testing::Helpers (load_bundle,
# shipped_bundle, sandbox), and each of their examples runs in its own
# sandbox, its bundles shut down after it. A spec under a bundle's own spec/
# folder (bundles/<name>/spec/) is tagged :bundle by itself; elsewhere tag the
# group:
#
#   RSpec.describe "my bundle", :bundle do
#     it("says hi") { expect(load_bundle(BUNDLE_DIR).command("/hi")).to eq("hi") }
#   end
RSpec.configure do |config|
  config.define_derived_metadata(file_path: %r{(?:\A|/)bundles/[^/]+/spec/}) { |metadata| metadata[:bundle] = true }
  config.include Samagotchi::Testing::Helpers, :bundle
  config.around(:each, :bundle) do |example|
    enter_sandbox
    example.run
  ensure
    leave_sandbox
  end
end
