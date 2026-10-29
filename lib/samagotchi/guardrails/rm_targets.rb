# frozen_string_literal: true

require_relative "shell_lex"
require_relative "shell_paths"
require_relative "path_resolve"

module Samagotchi
  module Guardrails
    # Whether a shell command's rm -rf reaches outside the tmp dirs (a
    # rule's rm: outside_tmp). Every rm with both -r and -f in it must
    # name only paths inside a tmp dir (not the tmp dir itself), resolved
    # the way ShellPaths resolves them (cd followed, ~/$HOME/$TMPDIR
    # expanded, symlinks resolved: /tmp/x -> / is outside). A target it
    # can't resolve ($VAR, a glob such as /tmp/*), an rm behind another
    # command (sudo rm, xargs rm) and a tmp dir the session's root is in
    # count as outside.
    module RmTargets
      RECURSIVE = /\A(?:--recursive|-[a-zA-Z]*[rR][a-zA-Z]*)\z/
      FORCE = /\A(?:--force|-[a-zA-Z]*f[a-zA-Z]*)\z/

      # A word that runs rm: rm, a path to it, or a script that names it
      # (sh -c 'rm -rf ~').
      RM_WORD = ->(word) { word == "rm" || word.end_with?("/rm") || (word.match?(ShellPaths::SCRIPT) && word.match?(/\brm\b/)) }
      # A redirection: the operator alone (its target is the next word) or
      # with its target.
      REDIRECT = /\A\d*(?:&>>?|>>?&?|<)/

      module_function

      # @param command [String]
      # @param cwd [String, nil] where the command starts
      # @param tmp_roots [Array<String>] resolved tmp dirs
      # @param session_root [String] the session's repo root (or cwd)
      def outside_tmp?(command, cwd:, tmp_roots:, session_root:, home: Dir.home, env: ENV)
        tokens = ShellLex.lex(command.to_s)
        # rm inside $(…) or backticks: the lexer keeps no body. A message
        # heredoc's text is data, so leave it out of this fallback.
        code = ShellLex.code_text(command.to_s)
        return true if tokens.any? { |_, value| value.include?(ShellLex::SUBST) } && code.match?(/\brm\b/)

        session = PathResolve.real(session_root.to_s)
        roots = PathResolve.tmp_roots(session: session, roots: tmp_roots)
        walk = ShellPaths::Walk.new(cwd, home, env)
        ShellLex.simple_commands(tokens).any? do |words|
          wide = words.is_a?(Array) && words.any?(&RM_WORD) && wide?(words, walk, roots)
          walk.step(words)
          wide
        end
      rescue ArgumentError, EncodingError
        true
      end

      # A simple command that runs rm: outside unless it is a plain rm
      # (env assignments before it at most) without -r and -f, or one whose
      # targets are all inside +roots+.
      def wide?(words, walk, roots)
        args = words.drop_while { |w| w.match?(/\A[A-Za-z_]\w*=/) }
        return true unless args.first == "rm"

        options, targets = split(args.drop(1))
        return false unless options.any? { |o| o.match?(RECURSIVE) } && options.any? { |o| o.match?(FORCE) }

        targets.empty? || targets.any? do |target|
          paths = walk.paths(target)
          paths.empty? || paths.flat_map { |path| PathResolve.reals(path) }.any? do |real|
            roots.none? { |tmp| PathResolve.strictly_under?(real, tmp, fold: false) }
          end
        end
      end

      # rm's options and targets, redirections left out.
      def split(args)
        options = []
        targets = []
        after_dashes = false
        skip = false
        args.each do |arg|
          if skip then skip = false
          elsif arg.match?(REDIRECT) then skip = arg.sub(REDIRECT, "").empty?
          elsif !after_dashes && arg == "--" then after_dashes = true
          elsif !after_dashes && arg.start_with?("-") && arg != "-" then options << arg
          else targets << arg
          end
        end
        [options, targets]
      end
    end
  end
end
