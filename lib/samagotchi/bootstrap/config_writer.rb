# frozen_string_literal: true

require "json"
require "yaml"
require "fileutils"
require "ipaddr"
require_relative "../atomic_file"
require_relative "../config"
require_relative "../yaml_lines"

module Samagotchi
  module Bootstrap
    # Writes the host `chi bootstrap` found into config.yml. With no file it
    # writes a small commented one; an existing file is the edge case and
    # gets a hosts: entry inserted as text (YAML.dump would drop the user's
    # comments), after a backup, and is checked by parsing it again: every
    # other key must be unchanged, or the backup goes back.
    class ConfigWriter
      include YAMLLines

      class Error < StandardError
      end

      # kind: :new (a fresh file), :appended, :exists (the host is already
      #   there as +existing+; nothing written), :snippet (a file chi can't
      #   edit safely: paste +text+ yourself), :failed (written, but the check
      #   failed and the backup is back), :dry_run (+text+ is what would be
      #   written or inserted, +where+ says where)
      # model_hint: a line for the user to add when default: exists without model
      Outcome = Data.define(:kind, :path, :backup, :text, :where, :name, :existing, :default_model, :model_hint) do
        def self.of(kind, path:, backup: nil, text: nil, where: nil, name: nil, existing: nil, default_model: nil,
                    model_hint: nil)
          new(kind: kind, path: path, backup: backup, text: text, where: where, name: name, existing: existing,
              default_model: default_model, model_hint: model_hint)
        end
      end

      HOSTS_LINE_RE = /\Ahosts:[ \t]*(#.*)?\z/
      SERVER_TRANSPORTS = ConfigFile::VALID_TRANSPORTS_FOR_CONFIG

      # The host part of a name: localhost/127.x → local, another IP → lan,
      # a domain → its second-level label (api.openai.com → openai).
      def self.derived_name(host)
        text = host.to_s.downcase.delete_prefix("[").delete_suffix("]")
        address = begin
          IPAddr.new(text)
        rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
          nil
        end
        return "local" if text == "localhost" || address&.loopback?
        return "lan" if address

        labels = text.split(".").reject(&:empty?)
        name = (labels.length >= 2 ? labels[-2] : labels.first).to_s.gsub(/[^a-z0-9._-]/, "-")
        name.match?(ConfigFile::HOST_NAME_RE) ? name : "host"
      end

      attr_reader :path

      # @param path [String] config.yml (a symlink is written through)
      # @param env [Hash] the environment for the check (SAMAGOTCHI_HOSTS_JSON
      #   is dropped: it would replace the file's hosts)
      # @param now [Proc] the time for the backup's name and the header
      def initialize(path:, env: ENV, now: -> { Time.now })
        @path = path
        @env = env.to_h.except("SAMAGOTCHI_HOSTS_JSON")
        @now = now
      end

      def exists? = File.file?(@path)

      # The file's data: {} for an empty file, nil when there is none or it
      # doesn't parse.
      def data
        return @data if defined?(@data)

        @data = exists? ? (parse(File.read(@path)) || {}) : nil
      rescue StandardError
        @data = nil
      end

      # The hosts entries the file routes to today, name → fields: its
      # hosts:, or with none the `default` chi makes from server.*.
      def current_hosts
        raw = data.is_a?(Hash) ? data["hosts"] : nil
        return raw.to_h { |name, fields| [name.to_s.downcase, fields.is_a?(Hash) ? fields : {}] } if raw.is_a?(Hash)
        return {} if data.is_a?(Hash) && data.key?("hosts")

        { "default" => server_entry }
      end

      # The name of an existing entry that points at the same server, or nil.
      def duplicate_of(fields)
        current_hosts.find { |_, existing| same_server?(existing, fields) }&.first
      end

      # The entry's name: +requested+ as given (it must be free), else
      # +base+, with -2, -3… when the name is taken or is the prefix of a
      # model id (chi would read "qwen3:8b" as host qwen3, model 8b).
      def host_name(base, requested: nil, model_ids: [])
        host_name_with_reason(base, requested: requested, model_ids: model_ids).first
      end

      # [name, reason]: reason is :taken when the name was suffixed because
      # config.yml already has it, :model_prefix when a model id's prefix
      # would read as a host, nil when the name is free as given.
      def host_name_with_reason(base, requested: nil, model_ids: [])
        taken = current_hosts.keys
        if requested
          name = requested.to_s.strip
          raise Error, "--name must match #{ConfigFile::HOST_NAME_RE.source}" unless name.match?(ConfigFile::HOST_NAME_RE)
          raise Error, "config.yml already has a host named '#{name}'; pick another --name" if taken.include?(name.downcase)

          return [name, nil]
        end

        prefixes = [*model_ids, configured_default_model].compact.map { |id| id.to_s.split(":", 2).first.downcase }
        name = base
        n = 1
        reason = nil
        while taken.include?(name) || prefixes.include?(name)
          reason ||= taken.include?(name) ? :taken : :model_prefix
          name = "#{base}-#{n += 1}"
        end
        [name, reason]
      end

      # Write the entry. @param fields [Hash] the hosts entry (string keys,
      # in the order written) @param model [String] the model id
      # @return [Outcome]
      def write(name:, fields:, model:, dry_run: false)
        default_model = "#{name}:#{model}"
        return write_new(name, fields, default_model, dry_run) unless exists?

        existing = duplicate_of(fields)
        return Outcome.of(:exists, path: @path, name: name, existing: existing) if existing

        append(name, fields, default_model, dry_run)
      end

      private

      def write_new(name, fields, default_model, dry_run)
        text = <<~YAML
          # Written by chi bootstrap on #{@now.call.strftime("%Y-%m-%d")}; see docs/configuration.md
          default:
            model: #{scalar(default_model)}
          hosts:
          #{entry_lines(name, fields, DEFAULT_INDENT, DEFAULT_INDENT).join}# More settings: docs/configuration.md#all-settings
        YAML
        return Outcome.of(:dry_run, path: @path, text: text, where: "a new file", name: name, default_model: default_model) if dry_run

        FileUtils.mkdir_p(File.dirname(@path))
        atomic_write(@path, text)
        Outcome.of(:new, path: @path, name: name, default_model: default_model)
      end

      def append(name, fields, default_model, dry_run)
        original = File.binread(@path).force_encoding(Encoding::UTF_8)
        return snippet(name, fields) unless data.is_a?(Hash) && !anchors?(original)

        lines, eol = lines_of(original)
        hosts_at = lines.index { |line| line.chomp.match?(HOSTS_LINE_RE) }
        return snippet(name, fields) if hosts_at.nil? && data.key?("hosts")

        default_entry = hosts_at || !routed? ? nil : server_entry
        add_model, model_hint = default_model_change(default_model)

        if hosts_at
          at, child, step = block_end(lines, hosts_at)
          inserted = entry_lines(name, fields, child, step)
          where = "in hosts:, after line #{at}"
          lines.insert(at, *inserted.map { |line| line.sub(/\n\z/, eol) })
        else
          inserted = ["hosts:\n", *(default_entry ? entry_lines("default", default_entry, DEFAULT_INDENT, DEFAULT_INDENT) : []),
                      *entry_lines(name, fields, DEFAULT_INDENT, DEFAULT_INDENT)]
          where = "a new hosts: section at the end"
          lines.concat(inserted.map { |line| line.sub(/\n\z/, eol) })
        end
        if add_model
          model_lines = ["default:\n", "  model: #{scalar(default_model)}\n"]
          inserted += model_lines
          lines.concat(model_lines.map { |line| line.sub(/\n\z/, eol) })
        end
        text = lines.join
        if dry_run
          return Outcome.of(:dry_run, path: @path, text: inserted.join, where: where, name: name,
                                      default_model: add_model ? default_model : nil, model_hint: model_hint)
        end

        real = File.realpath(@path)
        backup = backup_path(real)
        FileUtils.cp(real, backup, preserve: true)
        atomic_write(real, text)
        expected = expected_data(name, fields, default_entry, add_model ? default_model : nil)
        unless written_ok?(real, expected, name)
          atomic_write(real, File.binread(backup))
          return Outcome.of(:failed, path: @path, backup: backup, text: snippet_text(name, fields), name: name)
        end

        Outcome.of(:appended, path: @path, backup: backup, name: name, default_model: add_model ? default_model : nil,
                              model_hint: model_hint)
      end

      # Where a new entry goes in the hosts: block starting at +hosts_at+:
      # its end (the first entry is the default host, so never first),
      # before trailing blank lines and comments shallower than an entry.
      # @return [index, entry indent, field indent step]
      def block_end(lines, hosts_at)
        stop = block_stop(lines, hosts_at)
        children = lines[(hosts_at + 1)...stop].reject { |line| blank_or_comment?(line) }
        child = children.first ? indent(children.first) : DEFAULT_INDENT
        field = children.find { |line| indent(line) > child }
        step = field ? indent(field) - child : child
        [insert_at(lines, hosts_at, stop, child), child, step]
      end

      def entry_lines(name, fields, child, step)
        ["#{" " * child}#{name}:\n", *fields.map { |key, value| "#{" " * (child + step)}#{key}: #{scalar(value)}\n" }]
      end

      # Strings double-quoted (JSON's quoting is valid YAML): model ids hold
      # "/" and ":".
      def scalar(value) = value.is_a?(Integer) ? value.to_s : JSON.generate(value.to_s)

      def snippet(name, fields)
        Outcome.of(:snippet, path: @path, text: snippet_text(name, fields), name: name)
      end

      def snippet_text(name, fields) = "hosts:\n#{entry_lines(name, fields, DEFAULT_INDENT, DEFAULT_INDENT).join}"

      # [add default.model?, a line to print instead]
      def default_model_change(default_model)
        return [false, nil] if configured_default_model
        return [false, "  model: #{scalar(default_model)}   # under default:"] if data.key?("default")

        [true, nil]
      end

      def configured_default_model
        return nil unless data.is_a?(Hash)

        section = data["default"]
        value = section.is_a?(Hash) ? section["model"] : nil
        value.to_s.strip.empty? ? nil : value.to_s.strip
      end

      # Whether bare model names go somewhere today: a default.model or a
      # server: section. Then a new hosts: block keeps that route as `default`.
      def routed?
        configured_default_model || data.key?("server")
      end

      # The `default` hosts entry chi derives from server.* when the file has
      # no hosts:, written out so a new hosts: block doesn't reroute bare models.
      def server_entry
        file = data.is_a?(Hash) ? data : {}
        host = Config.resolve("server.host", file_data: file, env: {}, cli_overrides: {}).to_s.strip
        port = Config.resolve("server.port", file_data: file, env: {}, cli_overrides: {}).to_i
        transport = Config.resolve("server.transport", file_data: file, env: {}, cli_overrides: {}).to_s.strip.downcase
        entry = { "host" => host.empty? ? "localhost" : host, "port" => port.positive? ? port : 8080 }
        entry["transport"] = transport if SERVER_TRANSPORTS.include?(transport) && transport != "llama_cpp"
        entry
      end

      def same_server?(existing, fields)
        a = location(existing)
        b = location(fields)
        a && b && a == b
      end

      # [scheme-less host, port, path] of an entry.
      def location(fields)
        url = fields["url"].to_s.strip
        unless url.empty?
          uri = URI.parse(url)
          return [uri.host.to_s.downcase, uri.port, uri.path.to_s.chomp("/")]
        end
        host = fields["host"].to_s.strip.downcase
        return nil if host.empty?

        port = fields["port"].to_s.strip.empty? ? 8080 : fields["port"].to_i
        [host, port, fields["api"].to_s == "openai" ? "/v1" : ""]
      rescue URI::InvalidURIError
        nil
      end

      def expected_data(name, fields, default_entry, default_model)
        expected = Marshal.load(Marshal.dump(data))
        hosts = expected["hosts"].is_a?(Hash) ? expected["hosts"] : {}
        hosts["default"] = default_entry if default_entry
        hosts[name] = fields
        expected["hosts"] = hosts
        expected["default"] = { "model" => default_model } if default_model
        expected
      end

      def written_ok?(real, expected, name)
        parse(File.read(real)) == expected &&
          ConfigFile.hosts_config(env: @env, path: real).key?(name.downcase)
      rescue StandardError
        false
      end

      def backup_path(real)
        stamp = @now.call.utc.strftime("%Y%m%dT%H%M%SZ")
        candidate = "#{real}.bak-#{stamp}"
        n = 1
        candidate = "#{real}.bak-#{stamp}-#{n += 1}" while File.exist?(candidate)
        candidate
      end

      # The target's mode is kept (a fresh file's when it is new).
      def atomic_write(target, text)
        perm = File.stat(target).mode & 0o7777 if File.exist?(target)
        AtomicFile.write(target, text, perm: perm)
      end
    end
  end
end
