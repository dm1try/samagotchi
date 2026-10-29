# frozen_string_literal: true

module Samagotchi
  module Guardrails
    # The guardrails' path primitives: how a path is expanded, resolved and
    # compared, shared by every surface that judges one (ProtectedPaths,
    # Outside, ShellPaths, RmTargets, ReviewPaths, PairCommand, Targets,
    # ParentApprovals, System 1's SelfProtect). Each surface keeps its own
    # predicate; this only says where a path lands and whether it is in a
    # dir. docs/internals/tool-guardrails.md maps which surface uses which.
    module PathResolve
      # How many symlinks .real follows on a path that doesn't exist
      # (about the kernel's own ELOOP limit).
      MAX_LINKS = 40

      # A dir's disk answer (.folds_case?), asked once per dir.
      FOLDS = {}
      FOLDS_MUTEX = Mutex.new

      module_function

      # +path+ as an absolute path the way the kernel opens it: ~ expanded,
      # relative to +base+, and each `..` taken from where the dir before it
      # really is (a `..` after a symlinked dir climbs out of its target,
      # not back to the link's parent as File.expand_path has it). It
      # differs from File.expand_path only for such a climb; the parts
      # after the last `..` are kept as given (symlinks not resolved).
      # A shell's cd may land at either (ShellPaths::Walk keeps both); a file
      # argument and a tool's path go through this.
      # @param path [String]
      # @param base [String, nil] for a relative path (Dir.pwd when nil)
      def expand(path, base = nil)
        path = path.to_s
        head, sep, tail = path.partition("/")
        path = "#{File.expand_path(head)}#{sep}#{tail}" if head.start_with?("~")
        path = File.join(File.expand_path(base || Dir.pwd), path) unless path.start_with?("/")
        parts = []
        path.split("/").each do |part|
          next if part.empty? || part == "."

          part == ".." ? parts = climb(parts) : parts << part
        end
        "/#{parts.join("/")}"
      end

      # The parts of +parts+'s parent dir: the lexical one unless the dir
      # is (or goes through) a symlink whose target's parent is elsewhere.
      def climb(parts)
        lexical = parts[0...-1]
        dir = "/#{parts.join("/")}"
        return lexical unless parts.any? && File.directory?(dir)

        physical = File.dirname(File.realpath(dir))
        return lexical if File.realpath("/#{lexical.join("/")}") == physical

        physical.split("/").reject(&:empty?)
      rescue SystemCallError
        lexical
      end

      # +path+ (.expand) with symlinks resolved on its longest existing
      # parent: where the kernel lands for it. A part that is a dangling
      # symlink is followed to its target (a write there creates the
      # target), up to MAX_LINKS times; the missing tail is kept as given.
      def real(path)
        path = expand(path)
        MAX_LINKS.times do
          resolved = existing_prefix_real(path)
          return resolved unless resolved.is_a?(Array)

          path = resolved.first
        end
        path
      rescue SystemCallError
        path
      end

      # The old, lexical answer: File.expand_path (lexical `..`), then
      # realpath of the longest existing prefix, stopping at a dangling
      # symlink. .reals keeps it beside .real.
      def lexical_real(path)
        path = File.expand_path(path)
        rest = []
        current = path
        until File.exist?(current) || current == File.dirname(current)
          rest.unshift(File.basename(current))
          current = File.dirname(current)
        end
        File.join(File.realpath(current), *rest)
      rescue SystemCallError
        path
      end

      # Every place +path+ may be judged as: .lexical_real (what these
      # checks always looked at) and .real (where the kernel lands), one
      # entry when they agree. A check that holds for any of them (a
      # protected dir, a secret) or refuses unless all of them are inside
      # (the project, tmp) refuses at least what it did with the lexical
      # answer alone.
      # @return [Array<String>]
      def reals(path) = [lexical_real(path), real(path)].uniq

      # realpath of +path+'s longest existing prefix with the rest
      # appended (a String), or [the path with the first dangling symlink
      # on the way replaced by its target] to resolve again.
      def existing_prefix_real(path)
        rest = []
        current = path
        until File.exist?(current) || current == File.dirname(current)
          if File.symlink?(current)
            target = expand(File.readlink(current), File.dirname(current))
            return [expand(File.join(target, *rest))]
          end
          rest.unshift(File.basename(current))
          current = File.dirname(current)
        end
        File.join(File.realpath(current), *rest)
      end
      private_class_method :climb, :existing_prefix_real

      # Whether +path+ (resolved) is +root+ or in it, +root+ resolved
      # either way (.reals).
      def within?(path, root)
        return false if root.nil? || root.to_s.empty?

        reals(root.to_s.chomp("/")).any? { |dir| under?(path, dir) }
      end

      # Whether +path+ is +dir+ or in it (both absolute, resolved): by their
      # text, or on a disk that folds case (macOS) by their text cased alike.
      # realpath gives an existing part its on-disk case, but a missing
      # tail keeps the case it was typed in (<state>/CONTEXT/x before
      # <state>/context exists), and the kernel will create it in the
      # folder that later answers to either.
      def under?(path, dir)
        return true if path == dir || path.start_with?(File.join(dir, ""))

        low = path.downcase
        low_dir = dir.downcase
        (low == low_dir || low.start_with?(File.join(low_dir, ""))) && folds_case?(dir)
      end

      # Whether the disk +path+'s deepest existing dir is on folds case: that
      # dir (or the first one above it with a letter in its name) answers to
      # its name with the case swapped. Asked once per dir.
      def folds_case?(path)
        probe = path
        probe = File.dirname(probe) until probe == "/" || File.directory?(probe)
        probe = File.dirname(probe) until probe == "/" || File.basename(probe).swapcase != File.basename(probe)
        return false if probe == "/"

        FOLDS_MUTEX.synchronize do
          FOLDS.fetch(probe) do
            other = File.join(File.dirname(probe), File.basename(probe).swapcase)
            FOLDS[probe] = File.exist?(other) && File.identical?(probe, other)
          end
        end
      rescue SystemCallError
        false
      end
    end
  end
end
