# frozen_string_literal: true

require_relative "../load_check/scan"

# script/partial-use: the two audit-round probes over lib/samagotchi. Both read
# the same Prism scan script/load-check uses (script/load_check/scan.rb) and
# never load a file. See script/partial-use and docs/testing.md.
module PartialUse
  ROOT = File.expand_path("../..", __dir__)
  BUNDLES = "lib/samagotchi/bundles/"

  # Every file the reports read, parsed but never executed, with its require
  # graph and the constants it names.
  class Units
    attr_reader :root, :units

    def initialize(root: ROOT)
      @root = File.expand_path(root)
      @units = files.to_h { |path| [path, LoadCheck::Scan.new(File.join(@root, path), @root)] }
      @defs = Hash.new { |hash, name| hash[name] = [] }
      @units.each do |path, unit|
        unit.defs.each { |def_| @defs[(def_.scope + def_.parts).join("::")] << path }
      end
      @reach = {}
    end

    # lib/samagotchi/**/*.rb, the shipped bundles apart, plus bin/*.
    def files
      absolute = Dir["#{@root}/lib/samagotchi/**/*.rb"] + Dir["#{@root}/bin/*"]
      absolute.uniq.map { |file| relative(file) }.reject { _1.start_with?(BUNDLES) }.sort
    end

    # A require target as a scanned path, or nil when it is a gem or stdlib.
    def internal(require)
      target = require.target.start_with?("/") ? require.target : "lib/#{require.target}"
      target = "#{target}.rb" unless target.end_with?(".rb")
      scanned = relative(File.expand_path(target, @root))
      @units.key?(scanned) ? scanned : nil
    end

    # The files this one pulls in at load time, transitively, itself apart.
    # skip drops one direct edge, which is how a door's own contribution is
    # measured: what is reached with it minus what is reached without it.
    def reach(path, skip: nil)
      @reach[[path, skip]] ||= begin
        seen = Set.new
        stack = direct(path, skip)
        until stack.empty?
          next_path = stack.pop
          next unless seen.add?(next_path)

          stack.concat(direct(next_path, nil))
        end
        seen
      end
    end

    # The file itself plus what it pulls in.
    def closure(path)
      reach(path) + Set.new([path])
    end

    def direct(path, skip = nil)
      @units[path].requires.filter_map { |require| internal(require) if require.load_time }
                        .reject { _1 == skip }.uniq
    end

    # The full name a constant as written means, following the lexical scopes;
    # nil when it is a stdlib or gem name out of scope.
    def resolve(parts, scope)
      return nil if parts.nil? || parts.empty?

      scope.size.downto(0) do |depth|
        name = (scope.first(depth) + parts).join("::")
        return name if @defs.key?(name)
      end
      nil
    end

    def known?(name)
      @defs.key?(name)
    end

    def definers(name)
      @defs[name]
    end

    private

    def relative(absolute)
      absolute.sub(%r{\A#{Regexp.escape(@root)}/}, "")
    end
  end
end
