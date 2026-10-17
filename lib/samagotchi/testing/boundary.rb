# frozen_string_literal: true

module Samagotchi
  module Testing
    # What a bundle's Ruby may reach of chi (docs/plugins.md, "Stable for
    # bundles"): ALLOWED is the checked copy of that list. #scan finds a
    # bundle's other references to Samagotchi:: and requires of chi's files;
    # EXCEPTIONS is what the shipped bundles reach today anyway, each with
    # why: the APIs to design before that bundle could leave chi's repo
    # (spec/samagotchi/testing/boundary_spec.rb keeps both exact).
    module Boundary
      # A name a bundle may use, and the file that defines it (a require of
      # it is fine too). A name allows itself, its methods (".x") and what
      # it holds ("::X"); one ending in a method or constant allows only that.
      Allowed = Data.define(:name, :file)

      ALLOWED = [
        Allowed.new(name: "Samagotchi::Plugin::Api", file: "samagotchi/plugin/api"),
        Allowed.new(name: "Samagotchi::Plugin::ToolResult", file: "samagotchi/plugin/tool_result"),
        Allowed.new(name: "Samagotchi::Plugin::ModelError", file: "samagotchi/plugin/context"),
        Allowed.new(name: "Samagotchi::Plugin::ModelCancelled", file: "samagotchi/plugin/context"),
        Allowed.new(name: "Samagotchi::Plugin::Service::Stopped", file: "samagotchi/plugin/service"),
        Allowed.new(name: "Samagotchi::Plugin::Sessions::Error", file: "samagotchi/plugin/sessions"),
        Allowed.new(name: "Samagotchi::Plugin::AttachedContext::Error", file: "samagotchi/plugin/attached_context"),
        Allowed.new(name: "Samagotchi::Plugin::Peer", file: "samagotchi/plugin/peer"),
        Allowed.new(name: "Samagotchi::Tools::ToolIndex::Tool", file: "samagotchi/tools/tool_index"),
        Allowed.new(name: "Samagotchi::Tools::ToolIndex::Group", file: "samagotchi/tools/tool_index"),
        Allowed.new(name: "Samagotchi::Tools::ToolIndex.schema_note", file: "samagotchi/tools/tool_index"),
        Allowed.new(name: "Samagotchi::Tools::ToolIndex.spec_tokens", file: "samagotchi/tools/tool_index"),
        Allowed.new(name: "Samagotchi::Tools::Execute::NAME", file: "samagotchi/tools/execute"),
        Allowed.new(name: "Samagotchi::Tools::Execute::TIMEOUT_PREFIX", file: "samagotchi/tools/execute"),
        Allowed.new(name: "Samagotchi::Tools::Execute::HANDED_OVER", file: "samagotchi/tools/execute"),
        Allowed.new(name: "Samagotchi::Tools::Execute.timeout_seconds", file: "samagotchi/tools/execute"),
        Allowed.new(name: "Samagotchi::Tools::TaskRuntime::TASKS_DIR", file: "samagotchi/tools/task_runtime"),
        Allowed.new(name: "Samagotchi::Tools::TaskRuntime::EXIT_CODE_FILENAME", file: "samagotchi/tools/task_runtime"),
        Allowed.new(name: "Samagotchi::AtomicFile.write", file: "samagotchi/atomic_file"),
        Allowed.new(name: "Samagotchi::Log.warn", file: "samagotchi/log"),
        Allowed.new(name: "Samagotchi::Log.debug", file: "samagotchi/log"),
        Allowed.new(name: "Samagotchi::Config.get", file: "samagotchi/config"),
        Allowed.new(name: "Samagotchi::VERSION", file: "samagotchi/version"),
        # The kit itself, for a bundle's own specs.
        Allowed.new(name: "Samagotchi::Testing", file: "samagotchi/testing")
      ].freeze

      # The kit's adapters, required by a bundle's specs.
      ALLOWED_REQUIRES = (ALLOWED.map(&:file) + %w[samagotchi/testing/rspec samagotchi/testing/minitest]).uniq.freeze

      SESSION = "a saved session (context sources are keyed by its id): needs a kit helper that saves one"
      SOURCES = "the session's context sources (the peer's inbox / outbox): needs a kit helper that attaches one"
      REF_LIMITS = "a ref's kinds and limits (event[:refs] checks them too): could be stable constants"
      # The peers' specs pair a session through its context sources.
      PEER_SPEC = {
        'require "samagotchi/context_sources"' => "spec: #{SOURCES}",
        "Samagotchi::Session.new_session" => "spec: #{SESSION}",
        "Samagotchi::ContextSources.session_location" => "spec: #{SOURCES}",
        "Samagotchi::ContextSources::Source.new" => "spec: #{SOURCES}",
        "Samagotchi::ContextSources::Fetched.new" => "spec: an outbox answer as the context poller records it"
      }.freeze

      # bundle => {reference => why}: what each shipped bundle reaches
      # beyond ALLOWED today, its specs' (why "spec: …") included.
      EXCEPTIONS = {
        "agents-md" => {
          'require "samagotchi/guardrails/context"' => "for GitInfo: a ctx helper for the checkout's files could replace it",
          "Samagotchi::Guardrails::GitInfo.new" => "the work tree's top for the AGENTS.md chain (ctx.repo_root covers the top only)"
        },
        "claude-peer" => PEER_SPEC,
        "codex-peer" => PEER_SPEC,
        "coordinator" => {
          "Samagotchi::MemoryPaths.scope_dir" => "where the coordinator's memories live: needs a ctx memory-path API",
          "Samagotchi::MemoryPaths" => "spec: checks /coordinate end reads no memories (MemoryPaths.scope_dir isn't called)"
        },
        "github-pr" => {
          "Samagotchi::Session.new_session" => "spec: #{SESSION} (ctx.delegate?, ctx.fork?, ctx.context read it)",
          "Samagotchi::ContextSources.session_location" => "spec: reads and removes the session's sources (added_by), " \
                                                            "which ctx.context.list doesn't show",
          'require "samagotchi/memory_bundle/installer"' => "spec: for Installer",
          "Samagotchi::MemoryBundle::Installer.new" => "spec: installs the bundle so its context provider resolves: " \
                                                       "needs a kit install helper",
          'require "samagotchi/context_providers"' => "spec: for ContextProviders",
          "Samagotchi::ContextProviders.resolve" => "spec: the manifest's URL provider through chi's own resolver",
          'require "samagotchi/answer_display"' => "spec: for AnswerDisplay",
          "Samagotchi::AnswerDisplay.new" => "spec: after_turn's present: helper, as chi's fire site builds it: " \
                                             "the kit could supply after_turn's fire-site keys",
          'require "samagotchi/answer_refs"' => "spec: for AnswerRefs",
          "Samagotchi::AnswerRefs.new" => "spec: after_turn's refs: helper, as chi's fire site builds it",
          "Samagotchi::Log" => "spec: stubs Log to check what ctx.log recorded: a kit log recorder could replace it"
        },
        "loop-guard" => {
          'require "samagotchi/llm/native_tool_normalizer"' => "spec: for NativeToolNormalizer",
          "Samagotchi::LLM::NativeToolNormalizer.normalize" => "spec: replays recorded calls in the shape chi's parser gives",
          "Samagotchi::Hooks::StreamWatch::EVERY_CHARS" => "spec: the stream watch's batch size (a ctx or kit value later)"
        },
        "skills" => {
          "Samagotchi::Tools::MemoryRead.memories_dir" => "lists the skill memories: needs a ctx memory-path API"
        },
        "mcp" => {
          'require "samagotchi/process_group"' => "for ProcessGroup.stop",
          "Samagotchi::ProcessGroup.stop" => "stops a server's process group: needs a ctx process API",
          'require "samagotchi/token_usage"' => "for CHARS_PER_TOKEN",
          "Samagotchi::TokenUsage::CHARS_PER_TOKEN" => "estimates a tool's tokens: could be a stable constant",
          'require "samagotchi/tool_declarations"' => "loaded for Api.tool_spec's schemas"
        },
        "slow-commands" => {
          'require "samagotchi/guardrails/shell_lex"' => "for ShellLex",
          "Samagotchi::Guardrails::ShellLex" => "splits a command into its parts: needs a stable shell-parsing helper",
          "Samagotchi::Tools::Execute.const_defined?" => "reads execute's limits that older chis lack, by reflection",
          "Samagotchi::Tools::Execute.const_get" => "reads execute's limits that older chis lack, by reflection"
        },
        "source-links" => {
          'require "samagotchi/ref"' => "for the Ref / RefAction limits",
          "Samagotchi::Ref::FILE" => REF_LIMITS,
          "Samagotchi::Ref::KIND.match?" => REF_LIMITS,
          "Samagotchi::Ref::MAX_LABEL" => REF_LIMITS,
          "Samagotchi::RefAction::MAX_LABEL" => REF_LIMITS,
          "Samagotchi::RefAction.http_url?" => "which URLs an action may open: could be a stable helper"
        }
      }.freeze

      # A Samagotchi:: name with what follows it (::X, .method).
      REFERENCE = /\bSamagotchi(?:::[A-Z]\w*)+(?:\.[a-z_]\w*[?!]?)?/
      # A require of one of chi's files.
      REQUIRE = %r{\brequire\s*\(?\s*["'](samagotchi(?:/[\w/]+)?)["']}

      # One reference outside ALLOWED, in a file of the bundle.
      Finding = Data.define(:reference, :file)

      module_function

      # The bundle's references to chi outside ALLOWED (its plugin, hooks,
      # scripts and specs: every .rb under +dir+), one per reference and
      # file, sorted.
      # @param dir [String] the bundle's folder
      # @return [Array<Finding>]
      def scan(dir)
        Dir.glob(File.join(dir, "**", "*.rb")).sort.flat_map do |path|
          text = File.read(path)
          refs = text.scan(REFERENCE).reject { |name| allowed?(name) }
          refs += text.scan(REQUIRE).flatten.reject { |file| ALLOWED_REQUIRES.include?(file) }.map { |file| %(require "#{file}") }
          file = path.delete_prefix("#{File.expand_path(dir)}/")
          refs.uniq.map { |reference| Finding.new(reference: reference, file: file) }
        end
      end

      # Whether a bundle may use +name+ ("Samagotchi::X::Y", maybe ".method").
      def allowed?(name)
        ALLOWED.any? do |entry|
          name == entry.name || name.start_with?("#{entry.name}.", "#{entry.name}::")
        end
      end
    end
  end
end
