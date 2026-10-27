# frozen_string_literal: true

module AffectedSpecs
  # Hints for what the timing cops can't see in a changed spec, from its
  # added lines only (docs/testing.md, "Waiting and time"): something
  # started with nothing added that waits for it (rule 3), and a
  # sub-second wall-clock bound (rule 5). +tree+ answers
  # added_lines(path): [[line number, text], …] and read(path): the whole file.
  class TimingHints
    STARTS = [
      ["starts a thread (Thread.new)", /\bThread\.(?:new|start|fork)\b/],
      ["calls .start", /\.start\b(?![?!:])/],
      ["spawns a process", /\b(?:Process\.)?spawn\(|\bProcess\.spawn\b/],
      ["forks", /\bProcess\.fork\b|(?<![.\w])fork\s*(?:do\b|\{)/]
    ].freeze
    # What stops and waits for what a spec started.
    WAITS = /\bjoin!|\bwait_for\b|\bwith_task_dir\b|\bProcess\.wait2?\b/
    # A bare spawn( is Kernel#spawn, which does start a process — unless the
    # file defines its own spawn helper (`def spawn(...)` builds a session with
    # Process.spawn stubbed, as spec/session_manager_spec.rb and
    # spec/chi_bundle_cli_spec.rb do), which starts nothing.
    BARE_SPAWN = /(?<![\w.:])spawn\s*\(/
    SPAWN_HELPER = /^\s*def spawn\b/
    BOUND = /\bbe\s*\(?\s*<=?\s*0?\.\d/
    STARTED = "with no join!, wait_for, with_task_dir or Process.wait added: a spec stops and waits for what it " \
              'starts (docs/testing.md, "Waiting and time", rule 3)'
    BOUNDED = 'adds a sub-second bound: only as "not the full N s", with 5x headroom on the slow laptop ' \
              '(docs/testing.md, "Waiting and time", rule 5)'

    def initialize(changed:, tree:)
      @changed = changed
      @tree = tree
    end

    def hints
      @changed.select { |path| spec?(path) }.flat_map { |path| hints_for(path, code_lines(path)) }
    end

    private

    def spec?(path)
      return false if path.start_with?("spec/fixtures/")

      path.match?(%r{\A(?:spec/.*\.rb|lib/samagotchi/bundles/[^/]+/spec/.*\.rb)\z})
    end

    # Added lines, without the comments. A spec that defines its own spawn
    # helper starts nothing with its bare spawn( calls, so those lines are not
    # starts there; the helper's def can predate the change, so the file itself
    # is read.
    def code_lines(path)
      lines = Array(@tree.added_lines(path)).reject { |_, text| text.lstrip.start_with?("#") }
      return lines unless lines.any? { |_, text| text.match?(BARE_SPAWN) } && spawn_helper?(path)

      lines.reject { |_, text| text.match?(BARE_SPAWN) }
    end

    def spawn_helper?(path) = @tree.read(path).to_s.match?(SPAWN_HELPER)

    def hints_for(path, lines)
      waits = lines.any? { |_, text| text.match?(WAITS) }
      hints = []
      unless waits
        STARTS.each do |what, pattern|
          at = numbers(lines, pattern)
          hints << "timing: #{path}:#{at} #{what} #{STARTED}" if at
        end
      end
      at = numbers(lines, BOUND)
      hints << "timing: #{path}:#{at} #{BOUNDED}" if at
      hints
    end

    def numbers(lines, pattern)
      hits = lines.select { |_, text| text.match?(pattern) }.map(&:first)
      hits.empty? ? nil : hits.join(",")
    end
  end
end
