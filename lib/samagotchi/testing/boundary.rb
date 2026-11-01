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
      LIB_DIR = File.expand_path("../..", __dir__)

      # A name a bundle may use, and the file that defines it (a require of
      # it is fine too). A name allows itself, its methods (".x") and what
      # it holds ("::X"); one ending in a method or constant allows only that.
      Allowed = Data.define(:name, :file)

      ALLOWED = [
        Allowed.new(name: "Samagotchi::Plugin::Api", file: "samagotchi/plugin/api"),
        Allowed.new(name: "Samagotchi::Plugin::ToolResult", file: "samagotchi/plugin/tool_result"),
        Allowed.new(name: "Samagotchi::Plugin::ModelError", file: "samagotchi/plugin/context"),
        Allowed.new(name: "Samagotchi::Plugin::ModelCancelled", file: "samagotchi/plugin/context"),
        Allowed.new(name: "Samagotchi::Plugin::HttpError", file: "samagotchi/plugin/http"),
        Allowed.new(name: "Samagotchi::Plugin::HttpCancelled", file: "samagotchi/plugin/http"),
        Allowed.new(name: "Samagotchi::Plugin::Http::Response", file: "samagotchi/plugin/http"),
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
        # Both bundles' goldens live in claude-peer's spec/.
        "claude-peer" => PEER_SPEC.merge(
          "Samagotchi::ContextSources.move" => "spec: a continue leaving the pairing behind, as SessionContinue " \
                                               "moves it: needs a kit helper that continues a session"
        ),
        "codex-peer" => PEER_SPEC,
        "coordinator" => {
          "Samagotchi::MemoryPaths.scope_dir" => "where the coordinator's memories live: needs a ctx memory-path API",
          "Samagotchi::MemoryPaths" => "spec: checks /coordinate end reads no memories (MemoryPaths.scope_dir isn't called)"
        },
        "github-pr" => {
          "Samagotchi::Session.new_session" => "spec: #{SESSION} (ctx.delegate?, ctx.fork?, ctx.context read it)",
          "Samagotchi::ContextSources.session_location" => "spec: reads and removes the session's sources (added_by), " \
                                                            "which ctx.context.list doesn't show",
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
          'require "samagotchi/tool_declarations"' => "loaded for Api.tool_spec's schemas",
          "Samagotchi::ProjectEnv" => "checks the worker has a project env (an older chi doesn't)",
          "Samagotchi::ProjectEnv.current" => "starts a server in the session's project env: needs a ctx tools-env API",
          "Samagotchi::ProjectEnv.respond_to?" => "checks the worker has ProjectEnv.spawn_env (an older chi doesn't)",
          "Samagotchi::ProjectEnv.spawn_env" => "starts a server in the session's project env: needs a ctx tools-env API"
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
      # A relative require that may leave the bundle.
      REQUIRE_RELATIVE = /\brequire_relative\s*\(?\s*["']([^"']+)["']/

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
          refs += text.scan(REQUIRE_RELATIVE).flatten.filter_map do |relative|
            target = File.expand_path(relative, File.dirname(path))
            next unless within?(target, LIB_DIR) && !within?(target, File.expand_path(dir))

            %(require_relative "#{relative}")
          end
          file = path.delete_prefix("#{File.expand_path(dir)}/")
          refs.uniq.map { |reference| Finding.new(reference: reference, file: file) }
        end
      end

      def within?(path, dir)
        path == dir || path.start_with?("#{dir}#{File::SEPARATOR}")
      end
      private_class_method :within?

      # Whether a bundle may use +name+ ("Samagotchi::X::Y", maybe ".method").
      def allowed?(name)
        ALLOWED.any? do |entry|
          name == entry.name || name.start_with?("#{entry.name}.", "#{entry.name}::")
        end
      end

      # A reference this chi still has, read as a constant path and, when the
      # source names one, the method on it. Anything else is a form we can't
      # read, and #gone? answers "still there" for it.
      NAME_AND_METHOD = /\A(?<name>Samagotchi(?:::[A-Z]\w*)+)(?:\.(?<method>[a-z_]\w*[?!]?))?\z/

      # Every .rb of this chi's library. Shipped bundles' own code is not chi's
      # internals: loading it here would run a bundle's plugin twice.
      CORE_FILES = Dir.glob(File.join(LIB_DIR, "**", "*.rb"))
                      .reject { |file| file.start_with?(File.join(LIB_DIR, "samagotchi", "bundles") + File::SEPARATOR) }
                      .sort.freeze

      # Whether this chi no longer has a reference #scan found: its constant
      # does not resolve, or the object behind it has no method the name
      # names. That is the one question `chi update` asks of a bundle it
      # didn't write (Check with installed: true); a name that still resolves
      # breaks nothing, so it gets no row.
      #
      # The trap: lib/samagotchi loads lazily — each command requires what it
      # uses — so the running process may simply not have a name yet, and
      # asking it directly would call that "gone". When a name does not
      # resolve, #load_chi requires every file of this chi's library and asks
      # again, so the answer does not depend on what happened to be loaded. It
      # is lazy: a bundle reaching nothing internal, or reaching only names
      # this process already has, never pays for it; and the load happens in
      # the forked child, not in the update itself. A name that still fails
      # after that is "gone" only if this chi's source defines it nowhere: a
      # file the child could not require says nothing either way.
      def gone?(reference)
        match = NAME_AND_METHOD.match(reference)
        return gone_require?(reference) if match.nil?
        return false if resolves?(match[:name], match[:method])

        load_chi
        return false if resolves?(match[:name], match[:method])

        !defined_in_source?(match[:name])
      end

      def resolves?(name, method)
        object = Object.const_get(name)
        method.nil? || object.respond_to?(method)
      rescue NameError
        false
      end
      private_class_method :resolves?

      # A require of one of chi's files is gone only when the file is not
      # there; a require_relative the scan accepted points at a file it found.
      def gone_require?(reference)
        match = %r{\Arequire "samagotchi(?:/([\w/]+))?"\z}.match(reference)
        match ? !File.file?(File.join(LIB_DIR, "#{["samagotchi", match[1]].compact.join("/")}.rb")) : false
      end
      private_class_method :gone_require?

      def load_chi
        return if @chi_loaded

        @chi_loaded = true
        @unloadable = []
        CORE_FILES.each do |file|
          require file
        rescue StandardError, ScriptError # ScriptError: a LoadError, as the kit's adapters give with no rspec installed
          @unloadable << file
        end
      end
      private_class_method :load_chi

      # A name that failed to resolve is "gone" only when no file of this chi
      # defines it: one the child could not require (a gem missing, say) says
      # nothing about what chi has.
      def defined_in_source?(path)
        last = path.split("::").last
        @unloadable.any? { |file| File.read(file).match?(/\b(?:module|class)\s+#{last}\b|\b#{last}\s*=/) }
      end
      private_class_method :defined_in_source?
    end
  end
end
