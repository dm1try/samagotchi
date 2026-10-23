# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "json"
require "rack/mock"

require "samagotchi/web/app"
require "samagotchi/web/principal"

# Who a chi web request is (App#principal_for), and the permission column
# of the route table it is checked against. Today every principal is the
# owner and every route :owner; the routes a participant may use come later.
RSpec.describe Samagotchi::Web::Principal do
  describe "the owner" do
    subject(:owner) { described_class::OWNER }

    it "is the owner and may use every route" do
      expect(owner).to be_owner
      expect(owner.permits?(:owner)).to be(true)
      expect(owner.permits?(:participant)).to be(true)
    end

    it "authors no turn (nil: an owner's turn carries no author)" do
      expect(owner.author).to be_nil
    end
  end

  describe "anyone else" do
    subject(:other) { described_class.new(kind: :participant, grant: grant) }

    let(:grant) { Struct.new(:author).new("p:p_0123abcd") }

    it "may use only a :participant route" do
      expect(other).not_to be_owner
      expect(other.permits?(:participant)).to be(true)
      expect(other.permits?(:owner)).to be(false)
    end

    it "authors its turns through its grant" do
      expect(other.author).to eq("p:p_0123abcd")
    end
  end
end

RSpec.describe Samagotchi::Web::App, "principals and route permissions" do
  let(:token) { "t0ken-t0ken-t0ken-t0ken-t0ken-t0ken-t0ken" }
  let(:lan_ip) { "192.168.1.55" }
  let(:state_dir) { Dir.mktmpdir("web-principal") }
  let(:public_dir) do
    Dir.mktmpdir("web-principal-public").tap { |dir| File.write(File.join(dir, "index.html"), "<html>chi</html>") }
  end
  let(:lan) { { ip: lan_ip, token: token } }
  let(:app) { described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0, lan: lan) }

  after do
    FileUtils.remove_entry(state_dir)
    FileUtils.remove_entry(public_dir)
  end

  def request(path, peer:, headers: {})
    env = Rack::MockRequest.env_for(path, **headers)
    env["HTTP_HOST"] = "#{lan_ip}:4567"
    env["REMOTE_ADDR"] = peer
    Rack::Request.new(env)
  end

  describe "the route table" do
    it "gives every route a permission, and a route without one fails here" do
      rows = described_class.const_get(:ROUTES)
      permissions = described_class.const_get(:ROUTE_PERMISSIONS)
      expect(rows).not_to be_empty
      rows.each do |row|
        verb, pattern, handler, permission, kind, *rest = row
        label = "#{verb} #{pattern.source} (#{handler})"
        expect(permissions).to include(permission), "#{label} has no permission (one of #{permissions.inspect})"
        expect([nil, :session]).to include(kind), "#{label}: #{kind.inspect} is not a route kind"
        expect(rest).to be_empty, "#{label} has extra columns: #{rest.inspect}"
      end
    end

    it "keeps every route the owner's for now" do
      expect(described_class.const_get(:ROUTES).map { |row| row[3] }.uniq).to eq([:owner])
    end
  end

  describe "#principal_for" do
    it "is the owner for a loopback peer, with no token" do
      expect(app.send(:principal_for, request("/api/sessions", peer: "127.0.0.1"))).to eq(Samagotchi::Web::Principal::OWNER)
    end

    it "is the owner for any peer when chi web isn't on the LAN" do
      plain = described_class.new(state_dir: state_dir, public_dir: public_dir, bridge_wait_timeout: 0)
      expect(plain.send(:principal_for, request("/api/sessions", peer: "192.168.1.20"))).to be_owner
    end

    it "is the owner for a LAN peer with the token as a Bearer header or the cookie" do
      bearer = request("/api/sessions", peer: "192.168.1.20", headers: { "HTTP_AUTHORIZATION" => "Bearer #{token}" })
      cookie = request("/api/sessions", peer: "192.168.1.20", headers: { "HTTP_COOKIE" => "chi_token=#{token}" })
      expect(app.send(:principal_for, bearer)).to be_owner
      expect(app.send(:principal_for, cookie)).to be_owner
    end

    it "is nobody for a LAN peer without the token, or with a wrong one" do
      expect(app.send(:principal_for, request("/api/sessions", peer: "192.168.1.20"))).to be_nil
      wrong = request("/api/sessions", peer: "192.168.1.20", headers: { "HTTP_AUTHORIZATION" => "Bearer nope" })
      expect(app.send(:principal_for, wrong)).to be_nil
    end

    it "reads only ?token= on the page's token trade, not the cookie" do
      trade = request("/?token=nope", peer: "192.168.1.20", headers: { "HTTP_COOKIE" => "chi_token=#{token}" })
      expect(app.send(:principal_for, trade)).to be_nil
      expect(app.send(:principal_for, request("/?token=#{token}", peer: "192.168.1.20"))).to be_owner
    end
  end

  describe "#route" do
    it "hands the handler the request's principal" do
      seen = nil
      allow(app).to receive(:handle_info) do |req|
        seen = app.send(:principal, req)
        [200, {}, []]
      end
      env = Rack::MockRequest.env_for("/api/info", "HTTP_AUTHORIZATION" => "Bearer #{token}")
      env["HTTP_HOST"] = "#{lan_ip}:4567"
      env["REMOTE_ADDR"] = "192.168.1.20"
      app.call(env)
      expect(seen).to eq(Samagotchi::Web::Principal::OWNER)
    end

    it "refuses an :owner route to a principal that isn't the owner (403 not_permitted)" do
      other = Samagotchi::Web::Principal.new(kind: :participant, grant: nil)
      allow(app).to receive(:principal_for).and_return(other)
      env = Rack::MockRequest.env_for("/api/info")
      env["HTTP_HOST"] = "127.0.0.1:4567"
      env["REMOTE_ADDR"] = "127.0.0.1"
      status, _headers, body = app.call(env)
      expect(status).to eq(403)
      expect(JSON.parse(body.join)["error"]).to eq("not_permitted")
    end
  end
end
