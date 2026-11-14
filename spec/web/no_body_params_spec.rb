# frozen_string_literal: true

require "spec_helper"

# Rack's req.params (and req.POST, form_pairs, update_param, delete_param,
# its Multipart parser) parse the body of any request whose Content-Type is
# urlencoded or multipart, whatever its method: a urlencoded body into
# memory (up to 4 MB), a multipart one into temp files (up to Rack's 10 GB),
# with no cap of chi's. chi web reads a query with req.GET and a body only
# through RequestBody#request_body, which is capped. A new body read under
# lib/samagotchi/web/ (any of those, rack.input, a .body.read) fails here;
# one that is really needed goes in ALLOWED with its reason. Comment lines
# are skipped; a code line counts whole (a "#" in a string hides nothing).
RSpec.describe "chi web's request body reads" do
  root = File.expand_path("../../lib/samagotchi/web", __dir__)
  # "relative/path.rb" => "why its body read is bounded or wanted"
  allowed = {
    "request_body.rb" => "the one capped read: request_body reads at most limit + 1 bytes"
  }.freeze
  pattern = /\.(params|POST)\b|form_pairs|update_param|delete_param|rack\.input|RACK_INPUT|Multipart|\.body\.read/
  body_read = ->(line) { !line.match?(/\A\s*#/) && line.match?(pattern) }

  it "reads no body but through request_body" do
    found = Dir.glob(File.join(root, "**", "*.rb")).flat_map do |path|
      rel = path.delete_prefix("#{root}/")
      next [] if allowed.key?(rel)

      File.readlines(path).each_with_index.filter_map do |line, index|
        "#{rel}:#{index + 1}: #{line.strip}" if body_read.call(line)
      end
    end

    expect(found).to be_empty, "use req.GET for the query and request_body for a body:\n#{found.join("\n")}"
  end

  it "sees each form, in code and after a # in a string, not on a comment line" do
    ['x = req.params["id"]', "v = req.POST", "req.form_pairs", "req.update_param(:a, 1)", "req.delete_param(:a)",
     'env["rack.input"].read', "env[Rack::RACK_INPUT]", "Rack::Multipart.parse_multipart(env)", "req.body.read",
     'log "a #b", req.params'].each { |line| expect(body_read.call(line)).to be(true), line }
    expect(body_read.call("  # req.params would parse the body")).to be(false)
    expect(body_read.call('x = req.GET["id"]')).to be(false)
  end

  it "allows only files that exist" do
    expect(allowed.keys.reject { |rel| File.exist?(File.join(root, rel)) }).to be_empty
  end
end
