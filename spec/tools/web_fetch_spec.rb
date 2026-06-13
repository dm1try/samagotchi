# frozen_string_literal: true
require "samagotchi/tools/web_fetch"
RSpec.describe Samagotchi::Tools::WebFetch do
  subject(:web_fetch) { described_class }
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
        result = web_fetch.call("  https://example.com  ")
        expect(result).not_to include("Error")
        expect(result).to include("Example Domain")
      end
    end
    context "when HTML response" do
      it "strips script and style elements" do
        result = web_fetch.call("https://example.com")
        expect(result).not_to include("<script")
        expect(result).not_to include("<style")
      end
    end
  end
end
