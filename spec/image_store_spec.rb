# frozen_string_literal: true

require "tmpdir"
require "zlib"
require "samagotchi/image_store"

RSpec.describe Samagotchi::ImageStore do
  def fixture(name) = File.join(File.expand_path("fixtures/images", __dir__), name)

  # A solid-colour RGB png of any size, built in Ruby (compresses to a few KB).
  def png_bytes(width, height)
    row = "\x00".b + ("\x40\x80\xC0".b * width)
    raw = row * height
    chunk = lambda do |type, data|
      [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
    end
    "\x89PNG\r\n\x1A\n".b + chunk.call("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")) +
      chunk.call("IDAT", Zlib::Deflate.deflate(raw)) + chunk.call("IEND", "")
  end

  let(:dir) { Dir.mktmpdir("chi-images") }
  let(:none) { Samagotchi::ImageResizer.new(nil) }
  let(:limits) { described_class::Limits.new(max_side: 1568, max_bytes: 3_750_000, max_per_request: 20) }

  after { FileUtils.rm_rf(dir) }

  describe Samagotchi::ImageHeader do
    {
      "tiny.png" => [:png, 3, 2], "tiny.jpg" => [:jpeg, 5, 4], "tiny.gif" => [:gif, 7, 6],
      "tiny.webp" => [:webp, 9, 8], "tiny_lossless.webp" => [:webp, 11, 10], "tiny_alpha.webp" => [:webp, 13, 12],
      "tiny.bmp" => [:bmp, 15, 14]
    }.each do |name, (format, width, height)|
      it "reads #{name} as #{format} #{width}×#{height}" do
        info = described_class.read(File.binread(fixture(name)))
        expect([info.format, info.width, info.height]).to eq([format, width, height])
      end
    end

    it "knows tiff and heic by their magic, without a size" do
      expect(described_class.read("II*\x00rest".b).format).to eq(:tiff)
      expect(described_class.read("\x00\x00\x00\x18ftypheic\x00\x00".b).format).to eq(:heic)
    end

    it "answers nil for text, even a text file named .png" do
      expect(described_class.read(File.binread(fixture("text.png")))).to be_nil
      expect(described_class.read("")).to be_nil
    end
  end

  describe ".ingest" do
    it "stores a small png as is and returns its ref" do
      ref = described_class.ingest(dir, path: fixture("tiny.png"), resizer: none, limits: limits)
      expect(ref).to include(mime: "image/png", width: 3, height: 2, name: "tiny.png", source: "user",
                             bytes: File.size(fixture("tiny.png")))
      expect(ref[:file]).to match(described_class::REF_RE)
      expect(File.binread(File.join(dir, ref[:file]))).to eq(File.binread(fixture("tiny.png")))
    end

    it "keeps jpeg, gif and webp and names jpeg files .jpg" do
      refs = %w[tiny.jpg tiny.gif tiny.webp].map { |n| described_class.ingest(dir, path: fixture(n), resizer: none, limits: limits) }
      expect(refs.map { |r| r[:mime] }).to eq(%w[image/jpeg image/gif image/webp])
      expect(refs.first[:file]).to end_with(".jpg")
    end

    it "stores the same picture once (dedupe by the stored bytes)" do
      a = described_class.ingest(dir, path: fixture("tiny.png"), resizer: none, limits: limits)
      b = described_class.ingest(dir, bytes: File.binread(fixture("tiny.png")), name: "paste.png", source: "tool",
                                      resizer: none, limits: limits)
      expect(b[:file]).to eq(a[:file])
      expect(b).to include(name: "paste.png", source: "tool")
      expect(Dir.children(File.join(dir, "images")).size).to eq(1)
    end

    it "refuses a file that isn't an image" do
      expect { described_class.ingest(dir, path: fixture("text.png"), resizer: none, limits: limits) }
        .to raise_error(described_class::Error, /text\.png is not an image/)
    end

    it "refuses a missing file" do
      expect { described_class.ingest(dir, path: File.join(dir, "nope.png"), resizer: none, limits: limits) }
        .to raise_error(described_class::Error, /no such file/)
    end

    it "refuses a too-large image when there is no tool to downscale it" do
      big = png_bytes(2560, 1600)
      expect { described_class.ingest(dir, bytes: big, name: "shot.png", resizer: none, limits: limits) }
        .to raise_error(described_class::Error, /shot\.png is too large \(2560×1600.*install ImageMagick or downscale it/)
    end

    it "refuses bmp without a tool" do
      expect { described_class.ingest(dir, path: fixture("tiny.bmp"), resizer: none, limits: limits) }
        .to raise_error(described_class::Error, /a bmp image; install ImageMagick/)
    end

    it "downscales through the resizer and reads the new size" do
      small = png_bytes(1568, 980)
      resizer = instance_double(Samagotchi::ImageResizer, available?: true)
      expect(resizer).to receive(:convert).with(anything, end_with("out.png"), format: :png, max_side: 1568) do |_in, out, **|
        File.binwrite(out, small)
        out
      end
      ref = described_class.ingest(dir, bytes: png_bytes(2560, 1600), name: "shot.png", resizer: resizer, limits: limits)
      expect(ref).to include(width: 1568, height: 980, mime: "image/png", bytes: small.bytesize)
    end

    it "re-encodes as jpeg when the png is still over max_bytes (no resize for a narrow one)" do
      jpeg = File.binread(fixture("tiny.jpg"))
      resizer = instance_double(Samagotchi::ImageResizer, available?: true)
      allow(resizer).to receive(:convert) do |_in, out, format:, **|
        File.binwrite(out, format == :png ? png_bytes(40, 40) + ("x" * 5000) : jpeg)
        out
      end
      tight = described_class::Limits.new(max_side: 1568, max_bytes: 1000, max_per_request: 20)
      ref = described_class.ingest(dir, bytes: png_bytes(50, 50) + ("x" * 5000), name: "big.png", resizer: resizer, limits: tight)
      expect(ref).to include(mime: "image/jpeg", width: 5, height: 4)
    end

    context "with the real tools" do
      %i[sips magick].each do |tool|
        it "downscales 2560×1600 to 1568×980 with #{tool}" do
          skip "#{tool} not installed" unless Samagotchi::ImageResizer.executable?(tool.to_s)

          ref = described_class.ingest(dir, bytes: png_bytes(2560, 1600), name: "shot.png",
                                            resizer: Samagotchi::ImageResizer.new(tool), limits: limits)
          expect([ref[:width], ref[:height], ref[:mime]]).to eq([1568, 980, "image/png"])
        end

        it "converts bmp to png with #{tool}" do
          skip "#{tool} not installed" unless Samagotchi::ImageResizer.executable?(tool.to_s)

          ref = described_class.ingest(dir, path: fixture("tiny.bmp"), resizer: Samagotchi::ImageResizer.new(tool), limits: limits)
          expect([ref[:width], ref[:height], ref[:mime]]).to eq([15, 14, "image/png"])
        end
      end
    end
  end

  describe ".valid_ref? and .base64" do
    let(:ref) { described_class.ingest(dir, path: fixture("tiny.png"), resizer: none, limits: limits) }

    it "accepts a stored ref, with symbol or string keys" do
      expect(described_class.valid_ref?(dir, ref)).to be(true)
      expect(described_class.valid_ref?(dir, ref.transform_keys(&:to_s))).to be(true)
      expect(described_class.base64(dir, ref)).to eq([File.binread(fixture("tiny.png"))].pack("m0"))
      expect(described_class.data_uri(dir, ref)).to start_with("data:image/png;base64,iVBOR")
    end

    it "rejects traversal, absolute paths, other names and missing files" do
      ["../x.png", "images/../../etc/passwd", "/etc/passwd", "images/abc.png", "images/#{"0" * 16}.svg",
       "images/#{"0" * 16}.png"].each do |file|
        expect(described_class.valid_ref?(dir, { file: file })).to be(false), file
      end
      expect(described_class.valid_ref?(dir, "images/x.png")).to be(false)
      expect { described_class.base64(dir, { file: "../x.png" }) }.to raise_error(described_class::Error)
    end

    it "rejects a symlink in the images folder" do
      link = File.join(dir, "images", "#{"a" * 16}.png")
      FileUtils.mkdir_p(File.dirname(link))
      File.symlink(fixture("tiny.png"), link)
      expect(described_class.valid_ref?(dir, { file: "images/#{"a" * 16}.png" })).to be(false)
    end
  end

  describe Samagotchi::ImageRef do
    it "labels a ref with its size and a token estimate" do
      expect(described_class.label({ name: "shot.png", width: 1280, height: 800 })).to eq("shot.png 1280×800 · ~1.3k tokens")
      expect(described_class.label({ name: "s.png", width: 280, height: 280 })).to eq("s.png 280×280 · ~100 tokens")
    end

    it "writes a placeholder" do
      expect(described_class.placeholder({ name: "shot.png", width: 1280, height: 800 }, "this model can't see images"))
        .to eq("[image shot.png 1280×800 not sent: this model can't see images]")
    end
  end

  it "reads its limits from config" do
    limits = described_class::Limits.from_config
    expect([limits.max_side, limits.max_bytes, limits.max_per_request]).to eq([1568, 3_750_000, 20])
  end
end
