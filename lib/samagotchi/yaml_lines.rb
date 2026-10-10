# frozen_string_literal: true

require "yaml"
require "psych"

module Samagotchi
  # Line helpers for editing a YAML file's text in place, so the user's
  # comments and layout stay (YAML.dump would drop them): where a top-level
  # block ends, where a new line goes in it, and whether the text holds
  # anything a line edit can't handle (anchors and aliases). Shared by
  # ConfigTextEdit (one section.key) and Bootstrap::ConfigWriter (a hosts:
  # entry).
  module YAMLLines
    DEFAULT_INDENT = 2

    module_function

    # +text+ as its lines (each keeping its line end, the last one given
    # one) and the line end it uses.
    # @return [Array(Array<String>, String)]
    def lines_of(text)
      eol = text.include?("\r\n") ? "\r\n" : "\n"
      lines = text.split(/(?<=\n)/)
      lines[-1] = "#{lines[-1]}#{eol}" if lines.any? && !lines[-1].end_with?("\n")
      [lines, eol]
    end

    # The index after the block whose header is lines[+at+]: its indented
    # lines, blank lines and comments.
    def block_stop(lines, at)
      stop = at + 1
      stop += 1 while stop < lines.length && inside_block?(lines[stop])
      stop
    end

    # Where a new child line of the block at +at+ (ending at +stop+) goes:
    # its end, before trailing blank lines and comments shallower than a
    # +child+ line.
    def insert_at(lines, at, stop, child)
      stop -= 1 while stop > at + 1 && (lines[stop - 1].strip.empty? || (comment?(lines[stop - 1]) && indent(lines[stop - 1]) < child))
      stop
    end

    def inside_block?(line)
      return true if line.strip.empty?
      return false if line.start_with?("---", "...")

      line.start_with?(" ", "\t") || comment?(line)
    end

    def blank_or_comment?(line) = line.strip.empty? || comment?(line)
    def comment?(line) = line.lstrip.start_with?("#")
    def indent(line) = line[/\A */].length

    def parse(text) = YAML.safe_load(text, permitted_classes: [], aliases: false)

    # Anchors and aliases: chi's reader refuses aliases, and an edit can't
    # know what an anchor shares. Text that doesn't parse counts too.
    def anchors?(text)
      stack = [Psych.parse_stream(text)]
      until stack.empty?
        node = stack.pop
        return true if node.is_a?(Psych::Nodes::Alias) || (node.respond_to?(:anchor) && node.anchor)

        stack.concat(Array(node.children)) if node.respond_to?(:children)
      end
      false
    rescue Psych::Exception
      true
    end
  end
end
