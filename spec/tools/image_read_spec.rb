# frozen_string_literal: true

require "spec_helper"
require_relative "../../lib/samagotchi/tools/image_read"

RSpec.describe Samagotchi::Tools::ImageRead do
  describe ".name" do
    it "returns the correct name" do
      expect(described_class.name).to eq("image_read")
    end
  end

  describe ".description" do
    it "returns a description" do
      expect(described_class.description).to be_a(String)
      expect(described_class.description).to include("image")
    end
  end

  describe ".call" do
    let(:temp_dir) { Dir.mktmpdir }
    let(:png_path) { File.join(temp_dir, "test.png") }
    let(:jpg_path) { File.join(temp_dir, "test.jpg") }
    let(:gif_path) { File.join(temp_dir, "test.gif") }
    let(:webp_path) { File.join(temp_dir, "test.webp") }

    before do
      # Create test images (1x1 pixel)
      require "mini_magick"
      MiniMagick::Tool::Convert.call(
        "-size", "1x1", "xc:white", png_path
      )
      MiniMagick::Tool::Convert.call(
        "-size", "1x1", "xc:white", jpg_path
      )
      MiniMagick::Tool::Convert.call(
        "-size", "1x1", "xc:white", gif_path
      )
      MiniMagick::Tool::Convert.call(
        "-size", "1x1", "xc:white", webp_path
      )
    end

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it "returns an error when path is empty" do
      result = described_class.call("")
      expect(result).to include("Error")
      expect(result).to include("path is required")
    end

    it "returns an error when file does not exist" do
      result = described_class.call("/nonexistent/path/image.png")
      expect(result).to include("Error")
      expect(result).to include("file not found")
    end

    it "returns an error when path is a directory" do
      result = described_class.call(temp_dir)
      expect(result).to include("Error")
      expect(result).to include("not a file")
    end

    it "returns an error for unsupported format" do
      txt_path = File.join(temp_dir, "test.txt")
      File.write(txt_path, "not an image")
      result = described_class.call(txt_path)
      expect(result).to include("Error")
      expect(result).to include("unsupported image format")
    end

    it "returns a valid data URI for PNG" do
      result = described_class.call(png_path)
      expect(result).to be_a(Hash)
      expect(result[:uri]).to start_with("data:image/png;base64,")
      expect(result[:mime_type]).to eq("image/png")
      expect(result[:size_bytes]).to be_a(Numeric)
      expect(result[:size_bytes]).to be_positive
    end

    it "returns a valid data URI for JPG" do
      result = described_class.call(jpg_path)
      expect(result).to be_a(Hash)
      expect(result[:uri]).to start_with("data:image/jpeg;base64,")
      expect(result[:mime_type]).to eq("image/jpeg")
    end

    it "returns a valid data URI for GIF" do
      result = described_class.call(gif_path)
      expect(result).to be_a(Hash)
      expect(result[:uri]).to start_with("data:image/gif;base64,")
      expect(result[:mime_type]).to eq("image/gif")
    end

    it "returns a valid data URI for WebP" do
      result = described_class.call(webp_path)
      expect(result).to be_a(Hash)
      expect(result[:uri]).to start_with("data:image/webp;base64,")
      expect(result[:mime_type]).to eq("image/webp")
    end

    it "returns base64 data that can be decoded" do
      result = described_class.call(png_path)
      uri = result[:uri]
      # Extract the base64 part (after "data:image/png;base64,")
      base64_part = uri.split(",").last
      decoded = Base64.strict_decode64(base64_part)
      expect(decoded.bytesize).to eq(result[:size_bytes])
    end

    it "handles permission denied gracefully" do
      unreadable_path = File.join(temp_dir, "unreadable.png")
      File.write(unreadable_path, "test")
      File.chmod(0o000, unreadable_path)
      result = described_class.call(unreadable_path)
      expect(result).to include("Error")
      expect(result).to include("permission denied")
      File.chmod(0o644, unreadable_path) # restore for cleanup
    end
  end
end
