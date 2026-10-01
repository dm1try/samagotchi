# frozen_string_literal: true

require "json"
require "yaml"
require "psych"

module Samagotchi
  # Sets one section.key in config.yml text, line by line, so the user's
  # comments and layout stay (YAML.dump would drop them), the way
  # Bootstrap::ConfigWriter inserts a host. A key already in the block is
  # replaced on its line (a comment after the old value goes with it), a new
  # one goes at the end of the block, a missing section at the end of the
  # file. The result is parsed again and must equal +expected+; when it
  # doesn't, or the text is something a line edit can't handle (a flow-style
  # section, anchors, a duplicate section), the whole file is dumped from
  # +expected+ instead.
  module ConfigTextEdit
    DEFAULT_INDENT = 2

    module_function

    # @param text [String, nil] the file's text (nil: no file)
    # @param section [String] a top-level key ("default")
    # @param key [String] the key under it; an existing key matches in any case
    # @param value [String] the value, written as a quoted string
    # @param expected [Hash] the whole file's data after the change
    # @return [String] the new text
    def set(text, section:, key:, value:, expected:)
      edited = text && edit(text, section, key, value)
      edited && parse(edited) == expected ? edited : YAML.dump(expected)
    rescue Psych::Exception
      YAML.dump(expected)
    end

    def edit(text, section, key, value)
      return nil if anchors?(text)

      # A key the lines below can't see (flow style, odd quoting) would end up
      # written twice, and YAML keeps the last one without a word.
      original = parse(text)
      original = {} unless original.is_a?(Hash)
      section_data = original[section]
      has_key = section_data.is_a?(Hash) && section_data.keys.any? { |k| k.to_s.downcase == key.downcase }

      eol = text.include?("\r\n") ? "\r\n" : "\n"
      lines = text.split(/(?<=\n)/)
      lines[-1] = "#{lines[-1]}#{eol}" if lines.any? && !lines[-1].end_with?("\n")
      header = /\A#{Regexp.escape(section)}:[ \t]*(#.*)?\z/
      starts = lines.each_index.select { |i| lines[i].chomp.match?(header) }
      return nil if starts.length > 1

      return nil if starts.empty? && original.key?(section)

      if starts.empty?
        lines.concat(["#{section}:#{eol}", "#{" " * DEFAULT_INDENT}#{key}: #{scalar(value)}#{eol}"])
        return lines.join
      end

      at = starts.first
      stop = at + 1
      stop += 1 while stop < lines.length && inside_block?(lines[stop])
      children = lines[(at + 1)...stop].reject { |line| line.strip.empty? || comment?(line) }
      child = children.first ? indent(children.first) : DEFAULT_INDENT
      new_line = "#{" " * child}#{key}: #{scalar(value)}#{eol}"
      found = ((at + 1)...stop).find { |i| indent(lines[i]) == child && key_of(lines[i])&.downcase == key.downcase }
      if found
        lines[found] = new_line
      else
        return nil if has_key

        stop -= 1 while stop > at + 1 && (lines[stop - 1].strip.empty? || (comment?(lines[stop - 1]) && indent(lines[stop - 1]) < child))
        lines.insert(stop, new_line)
      end
      lines.join
    end

    def key_of(line)
      line[/\A\s*(["']?)([^"':#\s][^"':#]*?)\1:(?:\s|\z)/, 2]
    end

    def inside_block?(line)
      return true if line.strip.empty?
      return false if line.start_with?("---", "...")

      line.start_with?(" ", "\t") || comment?(line)
    end

    def comment?(line) = line.lstrip.start_with?("#")
    def indent(line) = line[/\A */].length

    # JSON's quoting is valid YAML: model ids hold "/" and ":".
    def scalar(value) = JSON.generate(value.to_s)

    def parse(text) = YAML.safe_load(text, permitted_classes: [], aliases: false)

    def anchors?(text)
      stack = [Psych.parse_stream(text)]
      until stack.empty?
        node = stack.pop
        return true if node.is_a?(Psych::Nodes::Alias) || (node.respond_to?(:anchor) && node.anchor)

        stack.concat(Array(node.children)) if node.respond_to?(:children)
      end
      false
    end
  end
end
