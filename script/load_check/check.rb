# frozen_string_literal: true

require "yaml"
require_relative "scan"

# script/load-check: the three load rules over lib/samagotchi and bin/chi,
# read with Prism and never loaded. See script/load-check and docs/testing.md.
module LoadCheck
  ROOT = File.expand_path("../..", __dir__)

  # One finding: rule 1 (call-time reference), 2 (load-time reference),
  # 3 (autoload naming a namespace). refs is how many places name it.
  Finding = Data.define(:rule, :path, :line, :constant, :why, :refs)

  Result = Data.define(:findings, :files, :allow_used, :allow_stale, :allow_stale_entries) do
    def references
      findings.sum(&:refs)
    end

    def rule_counts
      findings.group_by(&:rule).transform_values(&:size)
    end

    def area_counts
      findings.group_by { area_of(_1.path) }.transform_values(&:size)
    end

    # lib/samagotchi/<dir or file>, bin/chi.
    def area_of(path)
      parts = path.split("/")
      parts.first == "lib" ? parts[0..2].join("/") : path
    end
  end

  # script/load_check/allow.yml: every finding the checker reports that a human
  # proved to be a false positive, with its reason.
  class AllowList
    Entry = Data.define(:rule, :file, :constant, :reason) do
      def match?(finding)
        AllowList.wild(rule, finding.rule.to_s) && AllowList.wild(file, finding.path) && AllowList.wild(constant, finding.constant)
      end
    end

    def self.read(path)
      return [] unless path && File.file?(path)

      document = YAML.load_file(path)
      Array(document).filter_map do |entry|
        next unless entry.is_a?(Hash)

        Entry.new(entry["rule"].to_s, entry["file"].to_s, entry["constant"].to_s, entry["reason"].to_s)
      end
    end

    def self.wild(pattern, value)
      pattern.include?("*") ? File.fnmatch(pattern, value) : pattern == value
    end
  end

  class Check
    BUNDLES = "lib/samagotchi/bundles/"

    def initialize(root: ROOT, allow: nil, paths: nil)
      @root = File.expand_path(root)
      @allow = AllowList.read(allow)
      @paths = paths
      @closures = {}
      @before = {}
    end

    def run
      scan
      findings = merge(rule1 + rule2 + rule3)
      kept = findings.reject { |finding| @allow.any? { |entry| entry.match?(finding) } }
      stale = @allow.reject { |entry| findings.any? { |finding| entry.match?(finding) } }
      Result.new(findings: kept, files: @units.size, allow_used: @allow.size - stale.size, allow_stale: stale.size,
                 allow_stale_entries: stale)
    end

    # One line per (rule, file, constant): the first reference's line and how
    # many there are.
    def merge(findings)
      findings.group_by { [_1.rule, _1.path, _1.constant] }.values.map do |group|
        first = group.first
        refs = group.size
        Finding.new(first.rule, first.path, group.map(&:line).min, first.constant,
                    refs > 1 ? "#{first.why} (#{refs} references)" : first.why, refs)
      end.sort_by { [_1.rule, _1.path, _1.line] }
    end

    private

    def files
      absolute = if @paths
                   @paths.map { |path| File.expand_path(path, @root) }
                 else
                   Dir["#{@root}/lib/samagotchi/**/*.rb"] + Dir["#{@root}/bin/*"]
                 end
      absolute.uniq.map { |path| path.sub(%r{\A#{Regexp.escape(@root)}/}, "") }
              .reject { _1.start_with?(BUNDLES) }.select { File.file?(File.join(@root, _1)) }.sort
    end

    def scan
      @units = files.to_h { |path| [path, Scan.new(File.join(@root, path), @root)] }
      @defs = Hash.new { |hash, name| hash[name] = [] }
      @units.each do |path, unit|
        unit.defs.each { |def_| @defs[(def_.scope + def_.parts).join("::")] << [path, def_.line] }
      end
    end

    # The full name a reference means, following the lexical scopes; nil when
    # it is a stdlib or gem name and therefore out of scope.
    def resolve(ref)
      ref.scope.size.downto(0) do |depth|
        name = (ref.scope.first(depth) + ref.parts).join("::")
        return name if @defs.key?(name)
      end
      nil
    end

    def internal(require)
      target = require.target.start_with?("/") ? require.target : "lib/#{require.target}"
      path = with_rb(target).sub(%r{\A#{Regexp.escape(@root)}/}, "")
      @units.key?(path) ? path : nil
    end

    def with_rb(path)
      path.end_with?(".rb") ? path : "#{path}.rb"
    end

    def autoload_target(autoload)
      internal(Require.new(autoload.target, autoload.line, true)) if autoload.target
    end

    # Paths this file pulls in, transitively. load_time_only keeps out the
    # requires inside method bodies.
    def closure(unit, load_time_only)
      key = [unit.path, load_time_only]
      @closures[key] ||= begin
        seen = Set.new
        stack = reached_from(unit, load_time_only)
        until stack.empty?
          path = stack.pop
          next unless seen.add?(path)

          stack.concat(reached_from(@units[path], load_time_only))
        end
        seen
      end
    end

    def reached_from(unit, load_time_only)
      unit.requires.filter_map { |require| internal(require) if !load_time_only || require.load_time } +
        unit.autoloads.filter_map { autoload_target(_1) }
    end

    # What is already loaded when this line runs: the requires above it, and
    # everything they load at their own load time.
    def loaded_before(unit, line)
      key = [unit.path, line]
      @before[key] ||= begin
        seen = Set.new
        stack = unit.requires.filter_map { |require| internal(require) if require.load_time && require.line < line }
        stack.concat(unit.autoloads.select { _1.line < line }.filter_map { autoload_target(_1) })
        until stack.empty?
          path = stack.pop
          next unless seen.add?(path)

          stack.concat(reached_from(@units[path], true))
        end
        seen
      end
    end

    def defined_here?(unit, name)
      @defs[name].any? { |path, _| path == unit.path }
    end

    def here_lines(unit, name)
      @defs[name].select { |path, _| path == unit.path }.map(&:last)
    end

    def defined_in(name, paths)
      @defs[name].any? { |path, _| paths.include?(path) }
    end

    def finding(rule, path, line, name, why)
      Finding.new(rule, path, line, name, why, 1)
    end

    def definers(name)
      @defs[name].map(&:first)
    end

    # Rule 1: a constant a method body names must be defined here or reachable
    # through this file's requires and autoloads, transitively.
    def rule1
      @units.flat_map do |_path, unit|
        reach = closure(unit, false)
        unit.refs.filter_map do |ref|
          next unless ref.stage == :call

          name = resolve(ref)
          next if name.nil? || defined_here?(unit, name) || defined_in(name, reach)

          finding(1, unit.path, ref.line, name, "no require or autoload here reaches #{definers(name).join(", ")}, which defines it")
        end
      end
    end

    # Rule 2: a constant evaluated while the file loads (superclass, include,
    # a class body, a default argument) must come from a file required above it;
    # a require cycle does not guarantee that.
    def rule2
      @units.flat_map do |_path, unit|
        unit.refs.filter_map do |ref|
          next unless ref.stage == :load

          name = resolve(ref)
          next if name.nil?

          if defined_here?(unit, name)
            lines = here_lines(unit, name)
            next if lines.any? { |line| line <= ref.line }

            finding(2, unit.path, ref.line, name, "defined in this file at line #{lines.min}, below the reference")
          elsif defined_in(name, loaded_before(unit, ref.line))
            cycle = definers(name).find { |path| path != unit.path && same_cycle?(unit.path, path) }
            cycle && finding(2, unit.path, ref.line, name,
                             "require cycle with #{cycle}: which file loads first decides whether #{name} is there")
          else
            finding(2, unit.path, ref.line, name, why_missing(unit, name))
          end
        end
      end
    end

    def why_missing(unit, name)
      cycle = definers(name).find { |path| same_cycle?(unit.path, path) }
      if cycle
        "require cycle between #{unit.path} and #{cycle}: the load order is not guaranteed"
      elsif defined_in(name, closure(unit, false))
        "#{definers(name).first} is required only inside a method body (line #{method_require_line(unit, name)})"
      else
        "nothing here requires #{definers(name).join(", ")}, which defines it"
      end
    end

    def method_require_line(unit, _name)
      unit.requires.select { |require| !require.load_time && internal(require) }.map(&:line).min
    end

    # Rule 3: an autoload may name only a constant defined in one file.
    def rule3
      @units.flat_map do |_path, unit|
        unit.autoloads.filter_map do |autoload|
          name = autoload.name
          next finding(3, unit.path, autoload.line, "(dynamic autoload)", "autoload name is dynamic and cannot be checked") if name.nil?

          definers = definers(name)
          target = autoload_target(autoload)
          if definers.size > 1
            others = definers.reject { _1 == target }
            covered = target && others.all? { |path| closure(@units[target], true).include?(path) }
            finding(3, unit.path, autoload.line, name,
                    "autoload names a namespace reopened in #{definers.size} files (#{others.first(3).join(", ")}…)" \
                    "#{covered ? " — the file it points to loads them all" : " — the file it points to does not load them all"}")
          elsif definers.empty? && target
            finding(3, unit.path, autoload.line, name, "the file it points to (#{target}) defines no #{name}")
          end
        end
      end
    end

    def graph
      @graph ||= @units.to_h { |path, unit| [path, unit.requires.filter_map { internal(_1) if _1.load_time }.to_set] }
    end

    def same_cycle?(a, b)
      component_of[a] == component_of[b]
    end

    # Tarjan: the strongly connected components of the load-time require graph.
    def component_of
      @components ||= begin
        order = {}
        low = {}
        stack = []
        on_stack = Set.new
        comp = {}
        id = 0
        visit = lambda do |node|
          order[node] = low[node] = order.size
          stack.push(node)
          on_stack.add(node)
          graph[node].each do |next_node|
            if order[next_node]
              low[node] = [low[node], order[next_node]].min if on_stack.include?(next_node)
            else
              visit.call(next_node)
              low[node] = [low[node], low[next_node]].min
            end
          end
          if low[node] == order[node]
            while (member = stack.pop)
              on_stack.delete(member)
              comp[member] = id
              break if member == node
            end
            id += 1
          end
        end
        @units.each_key { |node| visit.call(node) unless order[node] }
        comp
      end
    end
  end
end
