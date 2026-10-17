# frozen_string_literal: true

require "json"
require_relative "log"
require_relative "ref"

module Samagotchi
  # The refs a plugin tool gives its row (chi.tool's refs: lambda, traceable
  # refs P5d): what the call traces to (a ticket, a PR, a file), each a Ref
  # whose +to_h+ the row carries as +refs+ on tool_call_started and
  # tool_call_completed (ToolRowFields::EVENT_KEYS), saved with the result
  # as tool_refs (ToolResponse::SAVED_KEYS) for a reload, which has no
  # plugins (MessageParts). Display only: the model never sees them.
  #
  # A file ref is any file under the session's folder (plan D7): a relative
  # path is resolved against it, a path outside it is dropped. The folder
  # counts under its own spelling and its real path (macOS /tmp is
  # /private/tmp), and a kept path is stored under the real one, so a
  # reload under either spelling keeps it. The page
  # shows the first ref on the row's title and the rest in its menu.
  module RowRefs
    # Per row, so a plugin can't bloat the events or session.json.
    MAX_REFS = 20
    # The row's refs' JSON; a ref that would cross it is left out.
    MAX_BYTES = 64 * 1024

    module_function

    # Runs +fn+ (the tool's refs: lambda, as ToolSpec#per_call wraps it: call →
    # a list of {kind:, target:, label:, actions:}) on +call+. Never
    # raises: a lambda that raises or returns something other than a list
    # gives none, and a bad ref is dropped; both are logged (warn, not
    # echoed: the turn's live region is on screen).
    # @param cwd [String, nil] the session's folder
    # @return [Array<Hash>] Ref#to_h each, deduped, at most MAX_REFS
    def for(fn, call, cwd:)
      return [] unless fn

      tool = call[:name].to_s
      raw = fn.call(call)
      return [] if raw.nil?
      raise ArgumentError, "refs: returned #{raw.class}, not a list" unless raw.is_a?(Array)

      build(raw, cwd) { |why| Log.warn(:plugins, "tool_refs_rejected", tool: tool, reason: why) }
    rescue StandardError => e
      Log.warn(:plugins, "tool_refs_failed", tool: tool, error: "#{e.class}: #{e.message}")
      []
    end

    # Stored refs (+raw+, a saved tool_refs entry), each rebuilt and
    # checked again as #for checks a lambda's: a stored file is never
    # trusted. What isn't valid any more is dropped, a relative path too
    # (it was stored absolute). Never raises: a reload must show the
    # conversation.
    # @return [Array<Hash>]
    def for_display(raw, cwd:)
      return [] unless raw.is_a?(Array)

      build(raw, cwd, relative: false) { |_why| nil }
    rescue StandardError
      []
    end

    # +raw+'s valid refs as Ref#to_h; +rejected+ gets why each other one
    # was dropped. +relative+: a relative file path is resolved against
    # +cwd+ (else dropped).
    def build(raw, cwd, relative: true, &)
      roots = roots(cwd)
      bytes = 2 # the list's []
      raw.each_with_object([]) do |value, refs|
        break refs if refs.length >= MAX_REFS

        hash = inside(Ref.from(value), roots, relative).to_h
        next if refs.include?(hash)

        size = JSON.generate(hash).bytesize + (refs.empty? ? 0 : 1)
        break refs if bytes + size > MAX_BYTES

        bytes += size
        refs << hash
      # One junk ref ({1 => "x"}, a nil target) goes alone.
      rescue ArgumentError, TypeError, NoMethodError => e
        yield(e.message)
      end
    end
    private_class_method :build

    # +cwd+ as [its spelling, its real path] (one when they are the same,
    # none without a +cwd+). absolute_path, not expand_path: a leading ~ is
    # a name, never a home. One realpath per row: the lambda's refs are
    # checked together. The answer's refs (AnswerRef) check against it too.
    def roots(cwd)
      return [] if cwd.to_s.empty?

      given = File.absolute_path(cwd.to_s)
      real = begin
        File.realpath(given)
      rescue SystemCallError
        given
      end
      [given, real].uniq
    end

    # +ref+ with a file's path absolute, resolved against the folder
    # (+roots+, #roots), under its real spelling: plan D7, for a plugin
    # row's refs and an answer's (AnswerRef) alike.
    # @raise [ArgumentError] a relative path with no folder (or not
    #   +relative+), or a path outside the folder
    def inside(ref, roots, relative)
      return ref unless ref.kind == Ref::FILE

      path = ref.target[:path]
      unless File.absolute_path?(path) || (relative && roots.any?)
        raise ArgumentError, "a file ref's relative path needs the session folder"
      end
      return ref if roots.empty?

      path = File.absolute_path(path, roots.first)
      root = roots.find { |dir| path == dir || path.start_with?(dir.end_with?("/") ? dir : "#{dir}/") }
      raise ArgumentError, "a file ref outside the session folder (#{path})" unless root

      ref.with(target: ref.target.merge(path: "#{roots.last}#{path.delete_prefix(root)}").freeze)
    end
  end
end
