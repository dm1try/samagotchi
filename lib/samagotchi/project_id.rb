# frozen_string_literal: true

require "securerandom"
require "yaml"
require_relative "log"

module Samagotchi
  # A marked project's id: the `id:` line of its .chi/project.yml
  # (MemoryPaths::MARKER), written by `chi project init`. A marked project
  # with an id keys its memories and project context sources by the id
  # (MemoryPaths.key_for), so moving or renaming the folder keeps them; one
  # without (an older marker, a bad hand edit) keys by its path. Git
  # repositories never have one: only MemoryPaths.lookup's :marker kind
  # reads it.
  #
  # Ids are `<basename>-<8 hex>`, a hyphen where a path key has its
  # underscore, so MemoryOrphans' "same basename, other hash" pattern never
  # takes an id folder for a moved project's path key.
  module ProjectId
    # A valid id: what a folder name and a URL segment can hold.
    PATTERN = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/
    # The marker is a small file; anything longer is read this far.
    READ_LIMIT = 4096

    # What a marker says: +id+ (a valid id, else nil) and +problem+ (why a
    # present `id:` is no id: "the id line is not valid YAML" …; nil with a
    # valid id or no id line at all). The one wording: the resolver's debug
    # line and `chi project init`'s report both say +problem+.
    Read = Data.define(:id, :problem) do
      def id? = !id.nil?
    end

    NONE = Read.new(id: nil, problem: nil)

    module_function

    # The marker at +root+ (a marked folder), read once: never raises.
    # @return [Read]
    def read(root)
      path = File.join(root, ".chi", "project.yml")
      parse(File.open(path, "rb") { |file| file.read(READ_LIMIT) }.to_s)
    rescue SystemCallError, IOError => e
      Read.new(id: nil, problem: "the marker can't be read (#{e.message})")
    end

    # @return [Read]
    def parse(text)
      text = text.dup.force_encoding(Encoding::UTF_8)
      return Read.new(id: nil, problem: "the marker is not UTF-8 text") unless text.valid_encoding?

      data = YAML.safe_load(text)
      return NONE if data.nil?
      return Read.new(id: nil, problem: "the marker is not a YAML mapping") unless data.is_a?(Hash)
      return NONE unless data.key?("id")

      check(data["id"])
    rescue Psych::Exception
      Read.new(id: nil, problem: "the marker is not valid YAML")
    end

    # @return [Read]
    def check(value)
      return Read.new(id: value, problem: nil) if value.is_a?(String) && value.match?(PATTERN)

      Read.new(id: nil, problem: "its id #{value.inspect[0, 80]} is not a valid id " \
                                 "(letters, digits, '_', '.', '-'; up to 64; a letter or digit first)")
    end

    # A fresh id for a folder named +basename+: the name's id-safe part and
    # 8 random hex digits.
    def generate(basename)
      name = basename.to_s.gsub(/[^A-Za-z0-9_.-]+/, "-").sub(/\A[^A-Za-z0-9]+/, "")[0, 55].sub(/[-.]+\z/, "")
      name = "project" if name.empty?
      "#{name}-#{SecureRandom.hex(4)}"
    end

    # The marker's text with its id line set to +id+ (replaced, or appended),
    # every other line kept.
    def with_id(text, id)
      line = "id: #{id}\n"
      lines = text.to_s.lines
      at = lines.index { |l| l.match?(/\Aid\s*:/) }
      return lines.tap { |all| all[at] = line }.join if at

      body = lines.join
      body += "\n" unless body.empty? || body.end_with?("\n")
      body + line
    end

    @logged = Set.new
    @logged_lock = Mutex.new

    # One debug line per (root, problem) and process: the resolver runs on
    # every memory call.
    def log_problem(root, read)
      return unless read.problem

      first = @logged_lock.synchronize { @logged.add?([root, read.problem]) }
      Log.debug(:memory, "project_id_ignored", root: root, problem: read.problem) if first
    end
  end
end
