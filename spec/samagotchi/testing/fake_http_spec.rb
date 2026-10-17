# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "yaml"
require "open3"
require "rbconfig"
require "samagotchi/testing"
require "samagotchi/cancellation_controller"

# Testing::FakeHttp, ctx.http's wire in a bundle's test: stubs, requests,
# unmatched, cancel, and the adapters' teardown check.
RSpec.describe Samagotchi::Testing::FakeHttp do
  let(:dir) { Dir.mktmpdir("fake-http-") }
  let(:loaded) { [] }
  let(:plugin) do
    <<~RUBY
      class Plugin
        def register(chi)
          chi.tool("classify", "classifies", params: { text: { type: "string", required: true } }) do |args, ctx|
            res = ctx.http.post_json("http://127.0.0.1:9000/classify", { text: args["text"] })
            res.ok? ? res.json["label"] : "status \#{res.status}"
          rescue Samagotchi::Plugin::HttpError => e
            "unreachable: \#{e.message}"
          end
          chi.tool("broad", "rescues everything", params: {}) do |_args, ctx|
            ctx.http.get("http://127.0.0.1:9000/nope").body
          rescue StandardError => e
            "rescued \#{e.class}"
          end
          chi.tool("patient", "calls while the turn is stopped", params: {}) do |_args, ctx|
            ctx.http.get("http://127.0.0.1:9000/slow").body
          rescue Samagotchi::Plugin::HttpCancelled
            "cancelled"
          end
          chi.on(:after_turn) { |_event, ctx| ctx.http.get("http://127.0.0.1:9000/hook") }
        end
      end
    RUBY
  end

  after do
    loaded.each(&:shutdown)
    FileUtils.rm_rf(dir)
  end

  def bundle_dir(root = dir, source: plugin)
    File.write(File.join(root, "plugin.rb"), source)
    File.write(File.join(root, "manifest.yml"),
               YAML.dump("name" => "fake-http-test", "version" => "1.0.0", "files" => {},
                         "plugin" => { "file" => "plugin.rb", "sha256" => "" }))
    root
  end

  def bundle
    @bundle ||= Samagotchi::Testing::Bundle.load(bundle_dir).tap { |b| loaded << b }
  end

  describe "stubs" do
    it "answers a String URL exactly and returns json: as a JSON body with its Content-Type" do
      bundle.http.stub(:post, "http://127.0.0.1:9000/classify", json: { label: "safe" })

      expect(bundle.tool("classify", text: "hello")).to eq("safe")
      request = bundle.http.requests.first
      expect(request).to have_attributes(method: "POST", url: "http://127.0.0.1:9000/classify")
      expect(request.json).to eq("text" => "hello")
      expect(request.headers).to include("Content-Type" => "application/json", "Accept" => "application/json")
      expect(bundle.http.unmatched).to be_empty
    end

    it "matches a Regexp against the full URL, a query included, and the method too" do
      fake = described_class.new
      fake.stub(:get, %r{/health\z}, status: 503, body: "down")
      fake.stub(:get, %r{/search\?q=}, body: "found")
      http = Samagotchi::Plugin::Http.new(bundle: "b", transport: fake)

      expect(http.get("http://svc/health")).to have_attributes(status: 503, body: "down", ok?: false)
      expect(http.get("http://svc/search?q=1").body).to eq("found")
      expect { http.post_json("http://svc/health", {}) }.to raise_error(Samagotchi::Testing::UnstubbedRequest)
    end

    it "lets a later stub win, answers every matching call, and gives headers lower-case and frozen" do
      fake = described_class.new
      fake.stub(:get, "http://svc/x", body: "first", headers: { "X-Id" => "1" })
      fake.stub(:get, "http://svc/x", body: "second", headers: { "X-Id" => 2 })
      http = Samagotchi::Plugin::Http.new(bundle: "b", transport: fake)

      2.times do
        res = http.get("http://svc/x")
        expect(res.body).to eq("second")
        expect(res.headers).to eq("x-id" => "2")
        expect(res.headers).to be_frozen
      end
    end

    it "answers a HEAD with an empty body" do
      fake = described_class.new.stub(:head, "http://svc/x", body: "ignored")

      expect(Samagotchi::Plugin::Http.new(bundle: "b", transport: fake).request(:head, "http://svc/x").body).to eq("")
    end

    it "takes a block that decides per request and may answer with a Hash or a Response" do
      fake = described_class.new
      fake.stub(:post, "http://svc/c") do |request|
        { json: { label: request.json["text"].include?("rm") ? "risky" : "safe" } }
      end
      fake.stub(:get, "http://svc/r") { Samagotchi::Plugin::Http::Response.new(status: 201, headers: {}.freeze, body: "made") }
      http = Samagotchi::Plugin::Http.new(bundle: "b", transport: fake)

      expect(http.post_json("http://svc/c", { text: "rm -rf" }).json).to eq("label" => "risky")
      expect(http.post_json("http://svc/c", { text: "ls" }).json).to eq("label" => "safe")
      expect(http.get("http://svc/r")).to have_attributes(status: 201, body: "made")
    end

    it "makes a counting sequence out of a block" do
      fake = described_class.new
      answers = [{ status: 500 }, { status: 200, body: "ok" }]
      fake.stub(:get, "http://svc/x") { |_request| answers.shift || { status: 200, body: "ok" } }
      http = Samagotchi::Plugin::Http.new(bundle: "b", transport: fake)

      expect(http.get("http://svc/x").status).to eq(500)
      expect(http.get("http://svc/x").body).to eq("ok")
    end

    it "raises the HttpError the real transport would for error: :refused and :timeout" do
      fake = described_class.new
      fake.stub(:get, "http://127.0.0.1:9000/x", error: :refused)
      fake.stub(:get, "http://127.0.0.1:9000/y", error: :timeout)
      http = Samagotchi::Plugin::Http.new(bundle: "b", transport: fake)

      expect { http.get("http://127.0.0.1:9000/x") }
        .to raise_error(Samagotchi::Plugin::HttpError, "GET 127.0.0.1:9000: connection refused")
      expect { http.get("http://127.0.0.1:9000/y") }.to raise_error(Samagotchi::Plugin::HttpError, /timed out/)
      expect(fake.unmatched).to be_empty
    end

    it "shows the plugin's own rescue a refused service" do
      bundle.http.stub(:post, "http://127.0.0.1:9000/classify", error: :refused)

      expect(bundle.tool("classify", text: "x")).to eq("unreachable: POST 127.0.0.1:9000: connection refused")
    end

    it "refuses a stub it can't make sense of" do
      fake = described_class.new

      expect { fake.stub(:trace, "http://svc/x") }.to raise_error(ArgumentError, /unknown HTTP method/)
      expect { fake.stub(:get, :nope) }.to raise_error(ArgumentError, /String or a Regexp/)
      expect { fake.stub(:get, "http://svc/x", error: :weird) }.to raise_error(ArgumentError, /unknown error/)
    end
  end

  describe "an unstubbed request" do
    it "raises UnstubbedRequest (not an HttpError), naming what is stubbed, and lands in requests and unmatched" do
      bundle.http.stub(:get, "http://127.0.0.1:9000/other")

      expect { bundle.ctx.http.get("http://127.0.0.1:9000/nope") }
        .to raise_error(Samagotchi::Testing::UnstubbedRequest, %r{no stub for GET http://127.0.0.1:9000/nope; stubbed: GET "http://127.0.0.1:9000/other"}) { |e|
          expect(e).not_to be_a(Samagotchi::Plugin::HttpError)
        }
      expect(bundle.http.unmatched.map(&:url)).to eq(["http://127.0.0.1:9000/nope"])
      expect(bundle.http.requests.map(&:url)).to eq(["http://127.0.0.1:9000/nope"])
    end

    it "is still in unmatched when the plugin rescued it broadly" do
      expect(bundle.tool("broad")).to eq("rescued Samagotchi::Testing::UnstubbedRequest")
      expect(bundle.http.unmatched.map(&:url)).to eq(["http://127.0.0.1:9000/nope"])
    end

    it "is told to the teardown: leave_sandbox returns the unmatched of every loaded bundle, after the cleanup" do
      helper = Class.new { include Samagotchi::Testing::Helpers }.new
      other = Dir.mktmpdir("fake-http-2-")
      first = helper.load_bundle(bundle_dir)
      second = helper.load_bundle(bundle_dir(other))
      first.tool("broad")
      second.tool("broad")
      work_dir = helper.sandbox.work_dir

      unmatched = helper.leave_sandbox

      expect(unmatched.size).to eq(2)
      expect(File.exist?(work_dir)).to be(false)
      expect(helper.leave_sandbox).to eq([])
    ensure
      FileUtils.rm_rf(other)
    end

    it "words the failure with each request" do
      requests = [described_class::Request.new(method: "GET", url: "http://a/x", headers: {}, body: nil)]

      expect(described_class.unmatched_message(requests))
        .to eq("ctx.http made 1 request no stub answered (bundle.http.stub):\n  GET http://a/x")
    end
  end

  describe "cancel" do
    it "raises HttpCancelled for a cancelled cancel:, before matching, recording nothing" do
      fake = described_class.new.stub(:get, "http://svc/x")
      http = Samagotchi::Plugin::Http.new(bundle: "b", transport: fake)
      cancelled = Samagotchi::CancellationController.new.tap { |c| c.cancel!(:manual) }

      expect { http.get("http://svc/x", cancel: cancelled) }.to raise_error(Samagotchi::Plugin::HttpCancelled)
      expect { http.get("http://svc/unstubbed", cancel: cancelled) }.to raise_error(Samagotchi::Plugin::HttpCancelled)
      expect(fake.requests).to be_empty
      expect(fake.unmatched).to be_empty
    end

    it "follows bundle.set(cancelled: true) for a call made without cancel:" do
      bundle.http.stub(:get, "http://127.0.0.1:9000/slow", body: "late")
      expect(bundle.tool("patient")).to eq("late")

      bundle.set(cancelled: true)
      expect(bundle.tool("patient")).to eq("cancelled")

      bundle.set(cancelled: false)
      expect(bundle.tool("patient")).to eq("late")
    end

    it "doesn't read the recorder for a cancel: it was given" do
      bundle.set(cancelled: true)
      bundle.http.stub(:get, "http://svc/x", body: "ok")

      expect(bundle.ctx.http.get("http://svc/x", cancel: Samagotchi::CancellationController.new).body).to eq("ok")
    end
  end

  describe "bundle.http" do
    it "is one FakeHttp per bundle, and a hook's call goes through it too" do
      bundle.http.stub(:get, "http://127.0.0.1:9000/hook", body: "")

      bundle.fire(:after_turn, status: "completed")

      expect(bundle.http).to be_a(described_class)
      expect(bundle.http.requests.map(&:url)).to eq(["http://127.0.0.1:9000/hook"])
    end
  end

  # The adapters' teardown check runs in a child rspec (and minitest) so a
  # failing example can be the thing under test.
  describe "the teardown check of the adapters" do
    let(:spec_source) do
      <<~RUBY
        require "samagotchi/testing/rspec"

        RSpec.describe "teardown", :bundle do
          it("passes with every request stubbed") do
            bundle = load_bundle(#{dir.inspect})
            bundle.http.stub(:get, "http://127.0.0.1:9000/nope", body: "ok")
            expect(bundle.tool("broad")).to eq("ok")
          end

          it("fails over a plugin that rescued an unstubbed request") do
            expect(load_bundle(#{dir.inspect}).tool("broad")).to eq("rescued Samagotchi::Testing::UnstubbedRequest")
          end

          it("keeps its own failure over an unstubbed request") do
            load_bundle(#{dir.inspect}).tool("broad")
            expect(1).to eq(2)
          end
        end
      RUBY
    end

    def run_child(command, env: {})
      out, status = Bundler.with_unbundled_env { Open3.capture2e(env, *command, chdir: dir) }
      [out, status]
    end

    it "fails an RSpec example that passed (after cleanup), and never hides a failing one" do
      bundle_dir
      File.write(File.join(dir, "child_spec.rb"), spec_source)
      repo = File.expand_path("../../..", __dir__)
      out, = run_child(["bundle", "exec", "rspec", "--options", File::NULL, "-I", File.join(repo, "lib"),
                        "--format", "json", "--no-color", File.join(dir, "child_spec.rb")],
                       env: { "BUNDLE_GEMFILE" => File.join(repo, "Gemfile") })
      json = JSON.parse(out[/^\{.*\}$/m])
      by_name = json["examples"].to_h { |example| [example["description"], example] }

      expect(by_name["passes with every request stubbed"]["status"]).to eq("passed")
      failed = by_name["fails over a plugin that rescued an unstubbed request"]
      expect(failed["status"]).to eq("failed")
      expect(failed["exception"]["class"]).to eq("Samagotchi::Testing::UnstubbedRequest")
      expect(failed["exception"]["message"]).to include("ctx.http made 1 request no stub answered", "GET http://127.0.0.1:9000/nope")
      own = by_name["keeps its own failure over an unstubbed request"]
      expect(own["exception"]["class"]).to eq("RSpec::Expectations::ExpectationNotMetError")
    end

    it "fails a Minitest test that passed, once, and keeps a failing one's own failure" do
      bundle_dir
      File.write(File.join(dir, "child_test.rb"), <<~RUBY)
        require "minitest/autorun"
        require "samagotchi/testing/minitest"

        class ChildTest < Samagotchi::Testing::Case
          def test_passes = (b = load_bundle(#{dir.inspect}); b.http.stub(:get, "http://127.0.0.1:9000/nope", body: "ok"); assert_equal("ok", b.tool("broad")))
          def test_unstubbed = assert_equal("rescued Samagotchi::Testing::UnstubbedRequest", load_bundle(#{dir.inspect}).tool("broad"))
          def test_own_failure = (load_bundle(#{dir.inspect}).tool("broad"); flunk("my own failure"))
        end
      RUBY
      repo = File.expand_path("../../..", __dir__)
      out, = run_child([RbConfig.ruby, "-I", File.join(repo, "lib"), File.join(dir, "child_test.rb")])
      skip "no minitest gem outside the bundle" if out.include?("cannot load such file -- minitest")

      expect(out).to include("3 runs", "2 failures")
      expect(out).to include("ChildTest#test_unstubbed", "ctx.http made 1 request no stub answered")
      expect(out).to include("my own failure")
      expect(out.scan("no stub answered").size).to eq(1)
    end
  end
end
