# frozen_string_literal: true

require_relative "session"
require_relative "session_access"
require_relative "session_access/remote"
require_relative "launch_mode"
require_relative "model_profile"
require_relative "cli/exit"
require_relative "terminal_ui"
require_relative "terminal_ui/attach_launcher"
require_relative "terminal_ui/remote_connector"

module Samagotchi
  # chi --remote NAME --attach ID | --resume ID | --dir DIR [-p TEXT]: the
  # attached TUI on a session of another machine, through its chi web
  # (bin/chi branches here after RunOptions.parse, before its own checks,
  # which are this machine's). The run flags come parsed; the ones that
  # run this machine's REPL or read its files were refused already
  # (SessionAccess::Contract::RUN). The setup flags go as typed: that
  # machine checks them against its own config and bundles.
  class RemoteAttachCommand
    # @param options [Hash] RunOptions.parse's
    # @param access [SessionAccess::Remote]
    def initialize(options, access:, stderr: $stderr, launcher: TerminalUI::AttachLauncher,
                   connector: TerminalUI::RemoteConnector)
      @options = options
      @access = access
      @stderr = stderr
      @launcher = launcher
      @connector = connector
    end

    # @return [Integer] the exit status: AttachLauncher.exit_status's, 1 a
    #   launch that failed, 2 a usage error
    def run
      if (conflict = LaunchMode.attached_conflict(@options))
        return failed(conflict)
      end

      existing = @options[:attach] || @options[:resume]
      return usage(new_needs_dir) if !existing && !absolute_dir?

      @access.require_feature!(SessionAccess::Remote::ATTACH_FEATURE)
      id = existing ? @access.resolve(existing) : create
      return id if id.is_a?(Integer)

      ignored(id) if existing
      launch(id, existing: existing)
    rescue TerminalUI::AttachLauncher::Error, SessionAccess::RemoteFailed, SessionAccess::Refused,
           SessionManager::OwnedByTUI, ModelProfile::MissingModel, ArgumentError => e
      e.is_a?(SessionAccess::BadRequest) ? usage(e.message) : failed(e.message)
    end

    private

    def launch(id, existing:)
      model = @options[:model]
      ended = @launcher.run(attach: (id if @options[:attach]), resume: (id if @options[:resume]), prompt: @options[:prompt],
                            model: (model if existing), no_interrupt: !!@options[:no_interrupt],
                            default_input: !@options[:no_default_input],
                            llm_context: (existing && @options[:llm_context]) || {},
                            thinking: (@options[:thinking] if existing),
                            connector: @connector.new(@access, session_id: id))
      @launcher.exit_status(ended)
    end

    # A new session there, idle (its -p goes in once attached), as chi send
    # --new makes one: the create's warnings printed as it prints them.
    # @return [String, Integer] its id, or the exit status of a refusal
    def create
      settings = Array(@options[:sets]).to_h do |pair|
        key, sep, value = pair.partition("=")
        return usage("--set takes KEY=VALUE, not #{pair}") if sep.empty? || key.strip.empty?

        [key.strip, value]
      end
      llm = @options[:llm_context] || {}
      words = SessionAccess::SetupWords.new(
        llm_context: (llm unless llm.empty?), thinking: @options[:thinking]&.to_s, toolkit: @options[:toolkit],
        tools: Array(@options[:tools]), no_tools: Array(@options[:no_tools]),
        settings: (settings unless settings.empty?), parent_answers: @options[:parent_answers]
      )
      created = @access.create(SessionAccess::NewSession.new(prompt: nil, idle: true, working_directory: @options[:dir],
                                                             model_name: @options[:model], setup: words,
                                                             client_id: @connector.client_id))
      @stderr.puts("chi: warning: #{created.model_warning}") if created.model_warning
      @stderr.puts("chi: warning: --parent-answers #{created.parent_answers_warning}") if created.parent_answers_warning
      created.id
    end

    # An existing session keeps its own setup: the line says which flags
    # went unused, as chi --attach here says it.
    def ignored(id)
      flags = [("--dir" if @options[:dir]), ("--toolkit" if @options[:toolkit]), ("--tool" if @options[:tools]),
               ("--no-tool" if @options[:no_tools]), ("--set" if @options[:sets]),
               ("--parent-answers" if @options[:parent_answers])].compact
      TerminalUI::AttachLauncher.warn_memory_flags_ignored(id, [], [], @stderr, toolkit_flags: flags)
    end

    def absolute_dir? = @options[:dir].to_s.start_with?("/")

    def new_needs_dir
      "a new session on #{@access.name} needs --dir, that machine's absolute path (or --attach ID / --resume ID)"
    end

    def failed(message)
      @stderr.puts("Error: #{message}")
      CLI::Exit::FAILED
    end

    def usage(message)
      @stderr.puts("Error: #{message}")
      CLI::Exit::USAGE
    end
  end
end
