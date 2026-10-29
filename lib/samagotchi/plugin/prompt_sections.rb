# frozen_string_literal: true

require_relative "../log"
require_relative "../toolkit"

module Samagotchi
  module Plugin
    # The system-prompt text plugins add (chi.prompt_section): one per
    # (bundle, name), each a block given the plugin's Context that returns
    # a String or nil (no section). SystemPrompt runs them inside a build
    # only (lazy, once per build key until a reset), never per request, on
    # whatever thread builds: a block must be quick and thread-safe.
    #
    # Prompt-cache contract (docs/internals/prompt-caching.md): sections go
    # sorted by (bundle, name), so the text is the same for the same
    # inputs. A block that raises, returns something other than a String
    # or nil, or text over MAX characters keeps the section's last good
    # text for this session (a skip on a transient error would break the
    # cache twice), with one warn; with no good text yet the section is
    # left out.
    class PromptSections
      # As a kit prompt's (Toolkit::PROMPT_MAX): a cached prefix, not a document.
      MAX = Toolkit::PROMPT_MAX
      NAME = /\A[a-z][a-z0-9_-]{0,31}\z/

      Section = Data.define(:bundle, :name, :block, :context)

      # A section as one build holds it.
      Built = Data.define(:bundle, :name, :text) do
        # "From <bundle> (<name>):\n<text>", as the prompt has it.
        def prompt_text = "From #{bundle} (#{name}):\n#{text}"

        # /stats' record (Engine#stats_snapshot's prompt_sections).
        def to_stats = { bundle: bundle, name: name }
      end

      def initialize
        @sections = []
        @mutex = Mutex.new
        # [session id, bundle, name] => the last good text (nil: none)
        @last_good = {}
        @warned = Set.new
      end

      # @raise [ArgumentError] a (bundle, name) already added
      def add(bundle:, name:, context:, &block)
        @mutex.synchronize do
          if @sections.any? { |section| section.bundle == bundle && section.name == name }
            raise ArgumentError, "prompt section #{name} is registered twice (bundle #{bundle})"
          end

          @sections << Section.new(bundle: bundle.to_s, name: name.to_s, block: block, context: context)
          @sections.sort_by! { |section| [section.bundle, section.name] }
        end
        nil
      end

      # @return [Boolean]
      def any? = @mutex.synchronize { @sections.any? }

      # Whether +bundle+ already has a section +name+.
      def registered?(bundle, name)
        @mutex.synchronize { @sections.any? { |section| section.bundle == bundle.to_s && section.name == name.to_s } }
      end

      # Run every block for +session_id+ and keep what they gave.
      # @param session_id [String, nil] whose last good text a failure keeps
      # @return [Array<Built>] in prompt order, the sections with text
      def render(session_id)
        sections = @mutex.synchronize { @sections.dup }
        sections.filter_map do |section|
          text = evaluate(section, session_id)
          Built.new(bundle: section.bundle, name: section.name, text: text) if text
        end
      end

      # The prompt text of +built+ (#render), nil without any.
      # @param built [Array<Built>]
      # @return [String, nil]
      def self.text(built)
        built.empty? ? nil : built.map(&:prompt_text).join("\n\n")
      end

      private

      def evaluate(section, session_id)
        key = [session_id, section.bundle, section.name]
        value = section.block.call(section.context)
        problem = problem_of(value)
        if problem
          keep_last_good(section, key, problem)
        else
          text = value.nil? ? nil : value.strip.freeze
          text = nil if text && text.empty?
          @mutex.synchronize { @last_good[key] = text }
          text
        end
      rescue StandardError => e
        keep_last_good(section, key, "#{e.class}: #{e.message}")
      end

      def problem_of(value)
        return nil if value.nil?
        return "returned #{value.class}, not a String or nil" unless value.is_a?(String)

        "is over #{MAX} characters" if value.strip.length > MAX
      end

      # One warn per section, session and problem; the last good text, or nil.
      def keep_last_good(section, key, problem)
        kept = @mutex.synchronize do
          first = @warned.add?([*key, problem])
          [@last_good[key], first]
        end
        text, first = kept
        if first
          Log.warn(:plugins, "prompt_section_failed", bundle: section.bundle, section: section.name,
                                                      error: problem.to_s[0, 200], kept: !text.nil?)
        end
        text
      end
    end
  end
end
