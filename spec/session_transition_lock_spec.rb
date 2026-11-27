# frozen_string_literal: true

require "spec_helper"
require "prism"

# The transition lock's one owner (SessionTransition): no other code in lib
# names continue.lock, so none flocks or probes it on its own. Built like
# spec/session_lifecycle_writers_spec.rb's visitor.
module SessionTransitionLockNames
  ROOT = File.expand_path("..", __dir__)
  OWNER = "lib/samagotchi/session_transition.rb"
  # Modules whose LOCK constant is the transition lock's name.
  HOLDERS = %w[SessionTransition ContinueIntent SessionContinue].freeze
  # Reads of the name outside OWNER that flock nothing, with their reason.
  ALLOWED = {
    "lib/samagotchi/continue_intent.rb#<top>" => "ContinueIntent::LOCK = SessionTransition::LOCK: the name for readers " \
                                                 "(specs holding a raw lock), never opened here.",
    "lib/samagotchi/session_manager/emptiness.rb#<top>" => "EMPTY_SKELETON_FILES lists the lock file's name: a " \
                                                           "folder holding only it is empty; never opened there."
  }.freeze

  class Names < Prism::Visitor
    attr_reader :found

    def initialize(path)
      super()
      @path = path.delete_prefix("#{ROOT}/")
      @scopes = []
      @methods = []
      @found = []
    end

    def visit_module_node(node) = scoped(node) { super }
    def visit_class_node(node) = scoped(node) { super }

    def visit_def_node(node)
      @methods << node.name
      super
    ensure
      @methods.pop
    end

    def visit_string_node(node)
      record(node, "\"continue.lock\"") if node.unescaped.include?("continue.lock")
      super
    end

    def visit_constant_path_node(node)
      parent = node.parent
      record(node, node.slice) if node.name == :LOCK && parent.respond_to?(:name) && HOLDERS.include?(parent.name.to_s)
      super
    end

    def visit_constant_read_node(node)
      record(node, "LOCK in #{@scopes.last}") if node.name == :LOCK && HOLDERS.include?(@scopes.last)
      super
    end

    private

    def scoped(node)
      @scopes << node.constant_path.slice.split("::").last
      yield
    ensure
      @scopes.pop
    end

    def record(node, what)
      @found << [what, "#{@path}##{@methods.last || "<top>"}", node.location.start_line]
    end
  end

  def self.names(root = ROOT)
    Dir.glob(File.join(root, "lib/**/*.rb")).reject { |path| path.include?("/bundles/") && path.include?("/spec/") }
       .sort.flat_map do |path|
      visitor = Names.new(path.sub(root, ROOT))
      Prism.parse_file(path).value.accept(visitor)
      visitor.found
    end
  end
end

RSpec.describe "only SessionTransition flocks continue.lock" do
  it "finds the lock's name nowhere in lib but SessionTransition and the allowed aliases (docs/internals/session-lifecycle.md)" do
    found = SessionTransitionLockNames.names
    outside = found.reject { |_what, site, _line| site.start_with?("#{SessionTransitionLockNames::OWNER}#") }
    unexpected = outside.reject { |_what, site, _line| SessionTransitionLockNames::ALLOWED.key?(site) }
    stale = SessionTransitionLockNames::ALLOWED.keys - outside.map { |_what, site, _line| site }

    failures = unexpected.map do |what, site, line|
      "#{site}:#{line} names the transition lock (#{what}); take it through SessionTransition " \
        "(exclusive / try_exclusive / shared / held?)"
    end
    failures.concat(stale.map { |site| "#{site} no longer names the lock; drop it from ALLOWED" })

    expect(failures).to be_empty, failures.join("\n")
    # Not vacuous: the owner itself names it.
    expect(found.map { |_what, site, _line| site }).to include("#{SessionTransitionLockNames::OWNER}#<top>")
  end
end
