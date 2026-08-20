
# frozen_string_literal: true
require "samagotchi/tools/web_fetch"
require "webmock/rspec"

RSpec.describe Samagotchi::Tools::WebFetch do
  subject(:web_fetch) { described_class }

  around do |example|
    WebMock.disable_net_connect!(allow_localhost: true)
    example.run
    WebMock.enable_net_connect!
  end

  describe ".name" do
    it "returns 'web_fetch'" do
      expect(web_fetch.name).to eq("web_fetch")
    end
  end

  describe ".description" do
    it "returns a non-empty description" do
      expect(web_fetch.description).to be_a(String)
      expect(web_fetch.description).not_to be_empty
    end
  end

  describe ".call" do
    context "with no arguments" do
      it "returns an error" do
        result = web_fetch.call(nil)
        expect(result).to include("Error")
        expect(result).to include("URL")
      end
    end

    context "with an empty string" do
      it "returns an error" do
        result = web_fetch.call("")
        expect(result).to include("Error")
        expect(result).to include("URL")
      end
    end

    context "with an invalid URL scheme" do
      it "returns an error for file:// URLs" do
        result = web_fetch.call("file:///etc/passwd")
        expect(result).to include("Error")
        expect(result).to include("invalid URL scheme")
      end

      it "returns an error for ftp:// URLs" do
        result = web_fetch.call("ftp://example.com")
        expect(result).to include("Error")
        expect(result).to include("invalid URL scheme")
      end
    end

    context "with an invalid URI format" do
      it "returns an error" do
        result = web_fetch.call("http://[invalid")
        expect(result).to include("Error")
        expect(result).to include("invalid URI")
      end
    end

    context "with whitespace-padded URL" do
      it "strips whitespace before fetching" do
        stub_request(:get, "https://example.com").to_return(
          status: 200,
          body: "<html><head><title>Example</title></head><body><h1>Example Domain</h1></body></html>",
          headers: { "Content-Type" => "text/html; charset=utf-8" },
        )
        result = web_fetch.call("  https://example.com  ")
        expect(result).not_to include("Error")
        expect(result).to include("Example Domain")
      end
    end

    context "when HTML response" do
      it "strips script and style elements" do
        stub_request(:get, "https://example.com").to_return(
          status: 200,
          body: "<html><body><script>alert(1)</script><style>body{}</style><h1>Hello</h1></body></html>",
          headers: { "Content-Type" => "text/html; charset=utf-8" },
        )
        result = web_fetch.call("https://example.com")
        expect(result).not_to include("<script")
        expect(result).not_to include("<style")
        expect(result).to include("Hello")
      end

      it "preserves noscript content" do
        stub_request(:get, "https://example.com").to_return(
          status: 200,
          body: "<html><body><noscript>JavaScript is disabled</noscript><p>Main content</p></body></html>",
          headers: { "Content-Type" => "text/html; charset=utf-8" },
        )
        result = web_fetch.call("https://example.com")
        expect(result).to include("JavaScript is disabled")
        expect(result).to include("Main content")
      end

      it "strips iframe and svg elements" do
        stub_request(:get, "https://example.com").to_return(
          status: 200,
          body: "<html><body><iframe>hidden</iframe><svg>hidden</svg><h1>Hello</h1></body></html>",
          headers: { "Content-Type" => "text/html; charset=utf-8" },
        )
        result = web_fetch.call("https://example.com")
        expect(result).to include("Hello")
      end
    end
  end

  describe "SSRF protection" do
    it "blocks localhost IP" do
      result = web_fetch.call("http://127.0.0.1:8080/path")
      expect(result).to include("SSRF")
    end

    it "blocks 0.0.0.0" do
      result = web_fetch.call("http://0.0.0.0/")
      expect(result).to include("SSRF")
    end

    it "blocks private IP ranges" do
      ["10.0.0.1", "192.168.1.1", "172.16.0.1"].each do |ip|
        result = web_fetch.call("http://#{ip}/")
        expect(result).to include("SSRF"), "Expected SSRF block for #{ip}, got: #{result}"
      end
    end

    it "blocks IPv6 loopback" do
      result = web_fetch.call("http://[::1]/")
      expect(result).to include("SSRF")
    end

    it "blocks IPv6 unique local" do
      result = web_fetch.call("http://[fd00::1]/")
      expect(result).to include("SSRF")
    end

    it "blocks IPv6 link-local" do
      result = web_fetch.call("http://[fe80::1]/")
      expect(result).to include("SSRF")
    end

    it "blocks IPv4-mapped IPv6 private addresses" do
      result = web_fetch.call("http://[::ffff:127.0.0.1]/")
      expect(result).to include("SSRF")
    end

    it "allows public domains" do
      stub_request(:get, "https://example.com").to_return(
        status: 200,
        body: "<html><body>ok</body></html>",
        headers: { "Content-Type" => "text/html; charset=utf-8" },
      )
      result = web_fetch.call("https://example.com")
      expect(result).not_to include("Error")
      expect(result).to include("ok")
    end
  end

  describe "truncation" do
    it "produces valid UTF-8 after truncation with multi-byte characters" do
      long_text = "Hello " + "\u{00e9}" * 20_000
      stub_request(:get, "https://long.example.com").to_return(
        status: 200,
        body: "<html><body>#{long_text}</body></html>",
        headers: { "Content-Type" => "text/html; charset=utf-8" },
      )
      result = web_fetch.call("https://long.example.com")
      expect(result).not_to include("Error")
      expect { result.encode("UTF-8") }.not_to raise_error
      expect(result).to include("[TRUNCATED")
      expect(result.bytesize).to be > described_class::MAX_OUTPUT_BYTES
    end

    it "does not truncate small content" do
      stub_request(:get, "https://small.example.com").to_return(
        status: 200,
        body: "<html><body>tiny</body></html>",
        headers: { "Content-Type" => "text/html; charset=utf-8" },
      )
      result = web_fetch.call("https://small.example.com")
      expect(result).not_to include("TRUNCATED")
      expect(result).to include("tiny")
    end
  end

  describe "text content types" do
    it "returns raw body for text/plain" do
      stub_request(:get, "https://example.com/plain").to_return(
        status: 200,
        body: "plain text content",
        headers: { "Content-Type" => "text/plain; charset=utf-8" },
      )
      result = web_fetch.call("https://example.com/plain")
      expect(result).to eq("plain text content")
    end

    it "returns valid UTF-8 for an ASCII-8BIT text body (regression: encoding mismatch)" do
      # Net::HTTP returns response bodies tagged ASCII-8BIT even when they hold
      # UTF-8 bytes (e.g. raw source files on raw.githubusercontent.com).
      body = "const x = 1; // café — ☕".b
      expect(body.encoding).to eq(Encoding::ASCII_8BIT)
      stub_request(:get, "https://example.com/raw").to_return(
        status: 200,
        body: body,
        headers: { "Content-Type" => "text/plain; charset=utf-8" },
      )
      result = web_fetch.call("https://example.com/raw")
      expect(result.encoding).to eq(Encoding::UTF_8)
      expect(result.valid_encoding?).to be(true)
      # Must not raise when interpolated into a UTF-8 string (logs/history).
      expect { "result: #{result}" }.not_to raise_error
      expect(result).to include("café")
    end

    it "returns error for unsupported content type" do
      stub_request(:get, "https://example.com/json").to_return(
        status: 200,
        body: '{"key": "value"}',
        headers: { "Content-Type" => "application/json" },
      )
      result = web_fetch.call("https://example.com/json")
      expect(result).to include("unsupported content type")
    end
  end

  describe "HTTP errors" do
    it "returns 404 message" do
      stub_request(:get, "https://example.com/notfound").to_return(
        status: 404,
        body: "Not found",
      )
      result = web_fetch.call("https://example.com/notfound")
      expect(result).to include("404")
    end

    it "returns 403 message" do
      stub_request(:get, "https://example.com/forbidden").to_return(
        status: 403,
        body: "Forbidden",
      )
      result = web_fetch.call("https://example.com/forbidden")
      expect(result).to include("403")
    end
  end
end
