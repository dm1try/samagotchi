# frozen_string_literal: true

# The mcp bundle's third plugin part (manifest.yml plugin: parts:, loaded
# before plugin.rb): a tools/call answer as the model reads it, its text and
# the images it attaches (image blocks, and an image file a stdio server
# names in its text). Plugin#call is its one caller.
require "json"
require "tmpdir"

class Plugin
  IMAGE_EXT = { "image/png" => "png", "image/jpeg" => "jpg", "image/gif" => "gif", "image/webp" => "webp" }.freeze

  private

  # The answer's text, and the images to attach: its image blocks, and a
  # text block that is only an image's path (#image_path).
  # @return [Array(String, Array<Hash>)]
  def content(result, server, tool)
    blocks = Array(result["content"])
    return [JSON.generate(result["structuredContent"]), []] if blocks.empty? && result["structuredContent"]

    images = []
    text = blocks.map do |block|
      case block["type"]
      when "text"
        line = block["text"].to_s
        paths = image_paths(line, server).reject { |path| images.any? { |image| image[:path] == path } }
        next line if paths.empty?

        notes = paths.map do |path|
          images << { path: path, name: File.basename(path) }
          "[image #{images.size}: #{File.basename(path)}]"
        end
        [line, *notes].join("\n")
      when "image"
        mime = block["mimeType"] || "unknown type"
        bytes = block["data"].to_s.unpack1("m")
        next "[image: #{mime}, empty]" if bytes.empty?

        images << { bytes: bytes, name: "#{tool}-#{images.size + 1}.#{IMAGE_EXT.fetch(mime, "img")}" }
        "[image #{images.size}: #{mime}]"
      when "audio" then "[audio: #{block["mimeType"] || "unknown type"}]"
      when "resource"
        resource = block["resource"] || {}
        mime = resource["mimeType"].to_s
        blob = resource["blob"].to_s
        if mime.start_with?("image/") && !blob.empty?
          bytes = blob.unpack1("m")
          next "[image: #{mime}, empty]" if bytes.empty?

          images << { bytes: bytes, name: "#{tool}-#{images.size + 1}.#{IMAGE_EXT.fetch(mime, "img")}" }
          "[image #{images.size}: #{mime}]"
        else
          resource["text"] || "[resource: #{resource["uri"]}]"
        end
      when "resource_link" then "[resource link: #{block["uri"]}]"
      else "[#{block["type"] || "unknown"} content]"
      end
    end.join("\n")
    [text, images]
  end

  # An absolute path ending in an image extension, inside a sentence
  # ("Saved screenshot to /tmp/shot.png."): no spaces, quotes or brackets.
  IMAGE_PATH_IN_TEXT = %r{(?<![\w/.~-])/[^\s"'`<>()\[\]{},;]+?\.(?:png|jpe?g|gif|webp)(?![\w/-])}i

  # The images +text+ names, when the server's attach_image_paths isn't
  # off: the whole text when it is one absolute path (any name), else each
  # absolute path in it that ends in an image extension. Each must be an
  # image file (by its bytes) under the system temp dir or the server's
  # cwd: a server's text can't pull in any image on disk.
  # @return [Array<String>] real paths, each once
  def image_paths(text, server)
    # A remote server can't name a local file usefully, and must not make
    # chi read one.
    return [] if server.config["attach_image_paths"] == false || server.url

    whole = text.strip
    candidates = if whole.start_with?("/") && !whole.include?("\n") && File.file?(whole)
                   [whole]
                 else
                   text.scan(IMAGE_PATH_IN_TEXT)
                 end
    candidates.filter_map { |path| image_path(path, server) }.uniq
  end

  # +path+'s real path when it is an image file under a root, else nil.
  def image_path(path, server)
    return nil unless File.file?(path)

    real = File.realpath(path)
    # degrade-ok: a root that is gone holds no image
    roots = [Dir.tmpdir, server.cwd].compact.map { |dir| File.realpath(dir) rescue nil }.compact
    return nil unless roots.any? { |root| real.start_with?(root.end_with?("/") ? root : "#{root}/") }

    image_magic?(real) ? real : nil
  rescue SystemCallError
    nil
  end

  # png, jpeg, gif or webp by the file's first bytes.
  def image_magic?(path)
    head = File.binread(path, 12).to_s.b
    head.start_with?("\x89PNG\r\n\x1a\n".b, "\xFF\xD8\xFF".b, "GIF87a", "GIF89a") ||
      (head.start_with?("RIFF") && head[8, 4] == "WEBP")
  end
end
