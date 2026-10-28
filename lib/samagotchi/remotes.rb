# frozen_string_literal: true

require "uri"
require "yaml"
require "fileutils"
require_relative "paths"
require_relative "atomic_file"

module Samagotchi
  # chi's remotes: other machines' chi web, each by a name chi --remote NAME
  # (or CHI_REMOTE=NAME) takes. They live in one file only you can read,
  # $XDG_CONFIG_HOME/samagotchi/remotes.yml (0600), their access tokens
  # inside (a token runs commands as you on that machine):
  #
  #   remotes:
  #     studio:
  #       url: http://192.168.1.29:4567
  #       token: …
  #
  # chi remote add / ls / rm write and read it (RemoteCommand); a write
  # replaces it whole (AtomicFile) under remotes.yml.lock.
  module Remotes
    FILE = "remotes.yml"
    # A name as git takes a remote's, short: letters, digits, - and _.
    NAME = /\A[A-Za-z0-9][A-Za-z0-9_-]{0,39}\z/

    # One remote: its +name+, chi web's +url+ (scheme, host and port, no
    # path) and its access +token+ (nil for a chi web on loopback only, no
    # LAN mode or proxy: it alone needs none, its loopback reached through
    # an SSH tunnel). #inspect leaves the token out.
    Entry = Data.define(:name, :url, :token) do
      # The host as an address, an IPv6 one bare (::1, not [::1]).
      def host = URI(url).hostname

      # How a failure names it: "remote studio (http://192.168.1.29:4567)".
      def label = "remote #{name} (#{url})"

      def inspect = "#<Samagotchi::Remotes::Entry name=#{name.inspect} url=#{url.inspect} token=[redacted]>"
      alias_method :to_s, :inspect
    end

    # A name or URL chi remote can't take, or a remotes.yml it can't read:
    # the message says which.
    class Invalid < StandardError; end

    # No remote by that name: the one message chi --remote, CHI_REMOTE and
    # chi remote rm give.
    class NotFound < Invalid
      def initialize(name)
        super("no remote #{name} (chi remote ls lists them; chi remote add NAME URL adds one)")
      end
    end

    module_function

    # @return [String] $XDG_CONFIG_HOME/samagotchi/remotes.yml
    def path(env: ENV) = File.join(Paths.config_home(env: env), Paths::APP_DIR, FILE)

    # @return [Array<Entry>] by name
    # @raise [Invalid] a file that isn't remotes.yml's shape
    def all(path: self.path)
      raw = File.exist?(path) ? YAML.safe_load_file(path) : nil
      remotes = raw.is_a?(Hash) ? raw["remotes"] : nil
      return [] if raw.nil? || (raw.is_a?(Hash) && remotes.nil?)
      raise Invalid, "#{Paths.tilde(path)}: remotes: is a map of names" unless remotes.is_a?(Hash)

      remotes.map do |name, fields|
        unless fields.is_a?(Hash) && fields["url"].is_a?(String)
          raise Invalid, "#{Paths.tilde(path)}: remote #{name} has no url"
        end

        Entry.new(name: name.to_s, url: fields["url"], token: fields["token"]&.to_s)
      end.sort_by(&:name)
    rescue Psych::Exception => e
      raise Invalid, "#{Paths.tilde(path)}: #{e.message}"
    end

    # @return [Entry]
    # @raise [NotFound]
    def find(name, path: self.path)
      all(path: path).find { |entry| entry.name == name } or raise NotFound, name
    end

    # Saves +entry+, replacing one of its name.
    def put(entry, path: self.path)
      locked(path) { write(all(path: path).reject { |other| other.name == entry.name } + [entry], path) }
    end

    # @return [Boolean] whether there was one
    def remove(name, path: self.path)
      locked(path) do
        entries = all(path: path)
        kept = entries.reject { |entry| entry.name == name }
        next false if kept.size == entries.size

        write(kept, path)
        true
      end
    end

    # @raise [Invalid] unless +name+ is one
    def check_name!(name)
      return name if NAME.match?(name.to_s)

      raise Invalid, "a remote's name is letters, digits, - and _ (up to 40), not #{name.inspect}"
    end

    # chi web's address as chi remote add takes it: http(s)://HOST:PORT,
    # the port 4567 (chi web's default) when none is given, no path.
    # @return [String]
    # @raise [Invalid]
    def normalize_url(text)
      text = text.to_s.strip
      text = "http://#{text}" unless text.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
      uri = URI.parse(text)
      unless %w[http https].include?(uri.scheme&.downcase) && uri.host && !uri.host.empty?
        raise Invalid, "give chi web's address, http://HOST:PORT, not #{text}"
      end
      raise Invalid, "give chi web's address alone, http://HOST:PORT, without a path or query" unless ["", "/"].include?(uri.path) && uri.query.nil?

      port = uri.port == uri.default_port && !text.match?(%r{://[^/]+:\d+}) ? 4567 : uri.port
      host = uri.host.include?(":") && !uri.host.start_with?("[") ? "[#{uri.host}]" : uri.host
      "#{uri.scheme.downcase}://#{host.downcase}:#{port}"
    rescue URI::InvalidURIError
      raise Invalid, "give chi web's address, http://HOST:PORT, not #{text}"
    end

    # The read-modify-write of +path+ under <path>.lock (0600), so two
    # chi remote add / rm at once never drop each other's entry.
    def locked(path)
      FileUtils.mkdir_p(File.dirname(path))
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
    private_class_method :locked

    def write(entries, path)
      FileUtils.mkdir_p(File.dirname(path))
      remotes = entries.sort_by(&:name).to_h { |entry| [entry.name, { "url" => entry.url, "token" => entry.token }.compact] }
      AtomicFile.write(path, YAML.dump({ "remotes" => remotes }), perm: 0o600)
    end
    private_class_method :write
  end
end
