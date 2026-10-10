# frozen_string_literal: true

require "json"
require "yaml"
require "psych"
require_relative "yaml_lines"

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
    extend YAMLLines

    DEFAULT_INDENT = YAMLLines::DEFAULT_INDENT

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

      lines, eol = lines_of(text)
      header = /\A#{Regexp.escape(section)}:[ \t]*(#.*)?\z/
      starts = lines.each_index.select { |i| lines[i].chomp.match?(header) }
      return nil if starts.length > 1

      return nil if starts.empty? && original.key?(section)

      if starts.empty?
        lines.concat(["#{section}:#{eol}", "#{" " * DEFAULT_INDENT}#{key}: #{scalar(value)}#{eol}"])
        return lines.join
      end

      at = starts.first
      stop = block_stop(lines, at)
      children = lines[(at + 1)...stop].reject { |line| blank_or_comment?(line) }
      child = children.first ? indent(children.first) : DEFAULT_INDENT
      new_line = "#{" " * child}#{key}: #{scalar(value)}#{eol}"
      found = ((at + 1)...stop).find { |i| indent(lines[i]) == child && key_of(lines[i])&.downcase == key.downcase }
      if found
        lines[found] = new_line
      else
        return nil if has_key

        lines.insert(insert_at(lines, at, stop, child), new_line)
      end
      lines.join
    end

    def key_of(line)
      line[/\A\s*(["']?)([^"':#\s][^"':#]*?)\1:(?:\s|\z)/, 2]
    end

    # JSON's quoting is valid YAML: model ids hold "/" and ":".
    def scalar(value) = JSON.generate(value.to_s)
  end
end
