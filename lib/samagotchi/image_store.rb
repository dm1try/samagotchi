# frozen_string_literal: true

require "digest"
require "fileutils"
require "open3"
require "securerandom"
require "tmpdir"
require_relative "atomic_file"
require_relative "config"

module Samagotchi
  # Reads an image's format and size from its first bytes, in pure Ruby.
  # Formats a model can take (png, jpeg, gif, webp) come with their size;
  # bmp comes with its size too, tiff and heic without (they are converted
  # before they are sent anyway).
  module ImageHeader
    Info = Data.define(:format, :width, :height)

    SENDABLE = %i[png jpeg gif webp].freeze
    CONVERTIBLE = %i[bmp tiff heic].freeze
    HEIC_BRANDS = %w[heic heix hevc hevx mif1 msf1].freeze

    # The format by magic bytes, or nil for anything else.
    def self.format_of(bytes)
      b = bytes.to_s.b
      return :png if b.start_with?("\x89PNG\r\n\x1A\n".b)
      return :jpeg if b.start_with?("\xFF\xD8\xFF".b)
      return :gif if b.start_with?("GIF87a", "GIF89a")
      return :webp if b.start_with?("RIFF") && b[8, 4] == "WEBP"
      return :bmp if b.start_with?("BM") && b.bytesize >= 26
      return :tiff if b.start_with?("II*\x00".b, "MM\x00*".b)
      return :heic if b[4, 4] == "ftyp" && HEIC_BRANDS.include?(b[8, 4])

      nil
    end

    # An Info, or nil when the bytes are not an image of a known format.
    # width/height are nil when the header doesn't say (tiff, heic, or a
    # truncated file).
    def self.read(bytes)
      b = bytes.to_s.b
      format = format_of(b)
      return nil unless format

      width, height = dimensions(format, b)
      Info.new(format: format, width: width, height: height)
    end

    def self.dimensions(format, b)
      case format
      when :png then b.bytesize >= 24 ? b[16, 8].unpack("NN") : nil
      when :gif then b.bytesize >= 10 ? b[6, 4].unpack("vv") : nil
      when :bmp then [b[18, 4].unpack1("l<").abs, b[22, 4].unpack1("l<").abs]
      when :jpeg then jpeg_dimensions(b)
      when :webp then webp_dimensions(b)
      end
    rescue StandardError
      nil
    end

    # Walks the JPEG segments to the first SOF marker (not DHT C4, JPG C8,
    # DAC CC), which holds the height and width.
    def self.jpeg_dimensions(b)
      pos = 2
      while pos + 9 < b.bytesize
        return nil unless b.getbyte(pos) == 0xFF

        marker = b.getbyte(pos + 1)
        if marker == 0xFF
          pos += 1
          next
        end
        if marker.between?(0xC0, 0xCF) && ![0xC4, 0xC8, 0xCC].include?(marker)
          height, width = b[pos + 5, 4].unpack("nn")
          return [width, height]
        end
        pos += 2 + b[pos + 2, 2].unpack1("n")
      end
      nil
    end

    def self.webp_dimensions(b)
      case b[12, 4]
      when "VP8 "
        w, h = b[26, 4].unpack("vv")
        [w & 0x3FFF, h & 0x3FFF]
      when "VP8L"
        b0, b1, b2, b3 = b[21, 4].bytes
        [1 + (((b1 & 0x3F) << 8) | b0), 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6))]
      when "VP8X"
        w = b[24, 3].bytes
        h = b[27, 3].bytes
        [1 + (w[0] | (w[1] << 8) | (w[2] << 16)), 1 + (h[0] | (h[1] << 8) | (h[2] << 16))]
      end
    end

    private_class_method :dimensions, :jpeg_dimensions, :webp_dimensions
  end

  # Downscales and converts images with whatever tool the machine has:
  # macOS sips first, then ImageMagick. `none` when neither is installed.
  class ImageResizer
    Error = Class.new(StandardError)

    attr_reader :tool

    def self.detect
      tool = if executable?("sips") then :sips
             elsif executable?("magick") then :magick
             end
      new(tool)
    end

    def self.executable?(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |dir|
        path = File.join(dir, name)
        File.file?(path) && File.executable?(path)
      end
    end

    def initialize(tool)
      @tool = tool
    end

    def available?
      !@tool.nil?
    end

    # Writes +input+ to +output+ as +format+ (:png or :jpeg), no bigger than
    # +max_side+ on its long side (never upscaled; nil keeps the size).
    def convert(input, output, format:, max_side: nil, quality: 85)
      raise Error, "no image tool (install ImageMagick)" unless available?

      command = @tool == :sips ? sips_command(input, output, format, max_side, quality) : magick_command(input, output, format, max_side, quality)
      out, status = Open3.capture2e(*command)
      raise Error, "#{@tool} failed: #{out.strip[0, 200]}" unless status.success? && File.size?(output)

      output
    end

    private

    def sips_command(input, output, format, max_side, quality)
      command = ["sips", "-s", "format", format.to_s]
      command += ["-s", "formatOptions", quality.to_s] if format == :jpeg
      command += ["--resampleHeightWidthMax", max_side.to_s] if max_side
      command + [input, "--out", output]
    end

    def magick_command(input, output, format, max_side, quality)
      command = ["magick", "#{input}[0]"]
      command += ["-resize", "#{max_side}x#{max_side}>"] if max_side
      command += ["-quality", quality.to_s] if format == :jpeg
      command + ["#{format}:#{output}"]
    end
  end

  # One-line texts about an image ref ({file:, mime:, width:, height:,
  # bytes:, name:, source:}).
  module ImageRef
    # Claude's rule of thumb (28×28 px per token). About 30% over on the
    # local Qwen, close enough for a label and the context estimate.
    def self.estimated_tokens(ref)
      w = ref[:width].to_i
      h = ref[:height].to_i
      return 0 unless w.positive? && h.positive?

      (w / 28.0).ceil * (h / 28.0).ceil
    end

    # "shot.png 1280×800 · ~1.3k tokens"
    def self.label(ref)
      tokens = estimated_tokens(ref)
      count = tokens >= 1000 ? "~#{(tokens / 1000.0).round(1)}k" : "~#{tokens}"
      "#{name(ref)} #{ref[:width]}×#{ref[:height]} · #{count} tokens"
    end

    # The text sent instead of an image the request leaves out.
    def self.placeholder(ref, reason)
      "[image #{name(ref)} #{ref[:width]}×#{ref[:height]} not sent: #{reason}]"
    end

    def self.name(ref)
      value = ref[:name].to_s
      value.empty? ? File.basename(ref[:file].to_s) : value
    end
  end

  # Stores images next to a session, in <session dir>/images/, under the
  # hash of the bytes that are sent (so the same picture is stored once).
  # Messages hold small refs to those files; the base64 is built only when
  # a request is sent.
  module ImageStore
    Error = Class.new(StandardError)

    DIR = "images"
    REF_RE = %r{\Aimages/[0-9a-f]{16}\.(png|jpe?g|gif|webp)\z}
    MIME = { png: "image/png", jpeg: "image/jpeg", gif: "image/gif", webp: "image/webp" }.freeze
    EXT = { png: "png", jpeg: "jpg", gif: "gif", webp: "webp" }.freeze
    # The most images one turn may carry (a client's refs, check_refs).
    MAX_TURN_REFS = 20
    # Nothing larger is even read.
    MAX_SOURCE_BYTES = 50 * 1024 * 1024

    Limits = Data.define(:max_side, :max_bytes, :max_per_request) do
      def self.from_config
        new(max_side: positive(Config.get("image.max_side"), 1568),
            max_bytes: positive(Config.get("image.max_bytes"), 3_750_000),
            max_per_request: positive(Config.get("image.max_per_request"), 20))
      rescue StandardError
        new(max_side: 1568, max_bytes: 3_750_000, max_per_request: 20)
      end

      def self.positive(value, fallback)
        value.to_i.positive? ? value.to_i : fallback
      end
    end

    # True when the file starts like an image of a known format.
    def self.image_file?(path)
      File.file?(path) && !ImageHeader.format_of(File.binread(path, 32)).nil?
    rescue StandardError
      false
    end

    # Stores one image (from +path+ or +bytes+) in +session_dir+ and returns
    # its ref. Converts bmp/tiff/heic to png, downscales to the long side,
    # re-encodes as jpeg when still over max_bytes. Raises Error with a line
    # for the user when the image can't be used.
    def self.ingest(session_dir, path: nil, bytes: nil, name: nil, source: "user",
                    resizer: ImageResizer.detect, limits: Limits.from_config)
      bytes = read_source(path) if path
      raise Error, "no image given" if bytes.nil? || bytes.empty?

      name = (name || (path && File.basename(path)) || "image").to_s
      raise Error, "#{name} is too large (over 50 MB)" if bytes.bytesize > MAX_SOURCE_BYTES
      info = ImageHeader.read(bytes)
      raise Error, "#{name} is not an image chi can send (png, jpeg, gif, webp)" unless info

      bytes, info = fit(bytes, info, name, resizer, limits)
      store(session_dir, bytes, info, name, source)
    end

    # A ref is only ever read when its file name matches REF_RE and the file
    # is inside this session's images folder.
    def self.valid_ref?(session_dir, ref)
      return false unless ref.is_a?(Hash)

      file = (ref[:file] || ref["file"]).to_s
      return false unless REF_RE.match?(file)

      path = File.join(session_dir.to_s, file)
      File.file?(path) && !File.symlink?(path)
    end

    # A turn's images from a client (the web, a Bridge request) as
    # [{file:, name:}], or a String saying what's wrong. Only refs to files
    # already in the session's images/ pass (an upload): never a path, so no
    # client can make the worker read a file.
    def self.check_refs(session_dir, raw)
      return [] if raw.nil?
      return "images must be a list" unless raw.is_a?(Array)
      return "at most #{MAX_TURN_REFS} images" if raw.size > MAX_TURN_REFS

      raw.map do |image|
        return "each image must be {file:, name:}" unless image.is_a?(Hash)

        ref = symbolize(image)
        return "images are refs to uploaded files, not paths" if ref.key?(:path)
        return "unknown image #{ref[:file].to_s[0, 80]}" unless valid_ref?(session_dir, ref)

        { file: ref[:file].to_s, name: File.basename(ref[:name].to_s)[0, 120] }
      end
    end

    # Messages seeded into another session (a plugin's ctx.sessions.fork):
    # each image ref's file is copied from +from+ into +to+ (both session
    # dirs; no +from+ copies none). A ref whose file isn't there is dropped, and its message says
    # so ("[image shot.png was not copied]").
    # @return [Array(Array<Hash>, Integer)] the messages, how many dropped
    def self.copy_refs(messages, from:, to:)
      dropped = 0
      copied = Array(messages).map do |message|
        images = message[:images] || message["images"]
        next message unless images.is_a?(Array) && !images.empty?

        kept, gone = from ? images.partition { |ref| valid_ref?(from, ref) } : [[], images]
        kept.each { |ref| copy_file(ref, from: from, to: to) }
        dropped += gone.size
        message = message.reject { |key, _| key.to_s == "images" }
        message[:images] = kept unless kept.empty?
        unless gone.empty?
          notes = gone.map { |ref| "[image #{ref.is_a?(Hash) ? ImageRef.name(symbolize(ref)) : "?"} was not copied]" }
          message[:content] = [(message.delete("content") || message[:content]).to_s, *notes].reject(&:empty?).join("\n")
        end
        message
      end
      [copied, dropped]
    end

    # One stored image's file from session dir +from+ into +to+ (kept when
    # it is there already: the name is the content's hash).
    def self.copy_file(ref, from:, to:)
      file = (ref[:file] || ref["file"]).to_s
      target = File.join(to.to_s, file)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(File.join(from.to_s, file), target) unless File.exist?(target)
    end

    # A ref for an image already stored in this session (a web upload),
    # rebuilt from the file itself: only its name comes from the caller.
    def self.ref_for(session_dir, file:, name: nil, source: "user")
      raise Error, "unknown image #{file.to_s[0, 80]}" unless valid_ref?(session_dir, { file: file })

      bytes = File.binread(File.join(session_dir.to_s, file.to_s))
      info = ImageHeader.read(bytes)
      raise Error, "unknown image #{file}" unless info && MIME.key?(info.format) && info.width

      name = File.basename(name.to_s).gsub(/[[:cntrl:]]/, "")[0, 120]
      { file: file.to_s, mime: MIME.fetch(info.format), width: info.width, height: info.height,
        bytes: bytes.bytesize, name: name.empty? ? File.basename(file.to_s) : name, source: source.to_s }
    end

    # The refs for a turn's images: {path:} is read and stored (only callers
    # on this machine pass it), {file:} must already be in this session.
    def self.resolve_all(session_dir, images, **options)
      Array(images).map do |image|
        image = symbolize(image)
        raise Error, "bad image #{image.inspect[0, 80]}" unless image.is_a?(Hash)

        if image[:path]
          ingest(session_dir, path: image[:path], name: image[:name], source: "user", **options)
        else
          ref_for(session_dir, file: image[:file], name: image[:name])
        end
      end
    end

    def self.path_for(session_dir, ref)
      raise Error, "bad image ref" unless valid_ref?(session_dir, ref)

      File.join(session_dir.to_s, (ref[:file] || ref["file"]).to_s)
    end

    def self.base64(session_dir, ref)
      [File.binread(path_for(session_dir, ref))].pack("m0")
    end

    def self.data_uri(session_dir, ref)
      "data:#{ref[:mime] || ref["mime"]};base64,#{base64(session_dir, ref)}"
    end

    # A ref read back from JSON (string keys) with symbol keys.
    def self.symbolize(ref)
      return ref unless ref.is_a?(Hash)

      ref.each_with_object({}) { |(k, v), h| h[k.to_sym] = v }
    end

    def self.read_source(path)
      expanded = File.expand_path(path.to_s)
      raise Error, "#{path}: no such file" unless File.exist?(expanded)
      raise Error, "#{path} is not a file" unless File.file?(expanded)
      raise Error, "#{path} is too large (over 50 MB)" if File.size(expanded) > MAX_SOURCE_BYTES

      File.binread(expanded)
    rescue SystemCallError => e
      raise Error, "#{path}: #{e.message}"
    end

    def self.fit(bytes, info, name, resizer, limits)
      convert = ImageHeader::CONVERTIBLE.include?(info.format)
      too_wide = info.width && info.height && [info.width, info.height].max > limits.max_side
      too_heavy = bytes.bytesize > limits.max_bytes
      return [bytes, info] unless convert || too_wide || too_heavy

      unless resizer.available?
        what = convert ? "a #{info.format} image" : "too large (#{info.width}×#{info.height}, #{bytes.bytesize} bytes)"
        raise Error, "#{name} is #{what}; install ImageMagick or downscale it"
      end

      Dir.mktmpdir("chi-image") do |dir|
        input = File.join(dir, "in")
        File.binwrite(input, bytes)
        # sips upscales to --resampleHeightWidthMax, so pass it only to shrink.
        side = too_wide ? limits.max_side : nil
        out = run(resizer, input, File.join(dir, "out.png"), :png, side)
        out = run(resizer, input, File.join(dir, "out.jpg"), :jpeg, side) if File.size(out) > limits.max_bytes
        result = File.binread(out)
        raise Error, "#{name} is still over #{limits.max_bytes} bytes after downscaling" if result.bytesize > limits.max_bytes

        [result, ImageHeader.read(result)]
      end
    end

    def self.run(resizer, input, output, format, max_side)
      resizer.convert(input, output, format: format, max_side: max_side)
    rescue ImageResizer::Error => e
      raise Error, e.message
    end

    def self.store(session_dir, bytes, info, name, source)
      raise Error, "#{name}: can't read its size" unless info&.width && info.height
      raise Error, "#{name} is not an image chi can send" unless MIME.key?(info.format)

      file = "#{DIR}/#{Digest::SHA256.hexdigest(bytes)[0, 16]}.#{EXT.fetch(info.format)}"
      path = File.join(session_dir.to_s, file)
      unless File.file?(path)
        FileUtils.mkdir_p(File.dirname(path))
        AtomicFile.write(path, bytes)
      end
      { file: file, mime: MIME.fetch(info.format), width: info.width, height: info.height,
        bytes: bytes.bytesize, name: name, source: source.to_s }
    end

    private_class_method :read_source, :fit, :run, :store
  end
end
