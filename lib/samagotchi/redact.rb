# frozen_string_literal: true

module Samagotchi
  # Secret shapes and host paths out of what a participant gets (the
  # session's folder as relative paths, home as ~). Defence in depth: the
  # allowlist (Web::ParticipantView) is the control; this catches a key the
  # model quoted in a reply, or one in a prompt. Also how the Engine reads a
  # Verify quote and ObjectivesCheck a text: as a participant's page shows it.
  # Pure, stdlib only: core files use it without loading chi web.
  module Redact
    # Who is looking: +author+ the participant's ("p:<id>"; nil for the
    # owner through the participant view: nothing is theirs), +cwd+ the
    # session's folder (tool paths are shown relative to it, only inside
    # it), +home+ the folder shown as ~, +secrets+ literal strings never
    # shown (the owner's token).
    Viewer = Data.define(:author, :cwd, :home, :secrets) do
      def initialize(author: nil, cwd: nil, home: Dir.home, secrets: [])
        super(author: author, cwd: cwd, home: home, secrets: Array(secrets).map(&:to_s).reject(&:empty?))
      end

      def own?(author) = !self.author.nil? && author.to_s == self.author
    end

    MARK = "[redacted]"
    PRIVATE_KEY = /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/m
    PATTERNS = [
      PRIVATE_KEY,
      /\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{16,}/,
      /\bgh[pousr]_[A-Za-z0-9]{20,}/,
      /\bgithub_pat_[A-Za-z0-9_]{20,}/,
      /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
      /\bxox[abprs]-[A-Za-z0-9-]{10,}/,
      /\bchp_[A-Za-z0-9_-]{20,}/,
      # A one-time link code (LinkCodes::CODE_RE): a bearer credential
      # until its grant expires (an owner's, 10 minutes).
      /\bchc_[A-Za-z0-9_-]{43}/,
      /\bAIza[0-9A-Za-z_-]{30,}/,
      /\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}/,
      /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/,
      %r{https://hooks\.slack\.com/services/[A-Za-z0-9/_-]+}
    ].freeze
    # The value after an Authorization (or a Bridge's secret,
    # BridgeSecret::HEADER) header or a token=/key= pair.
    VALUES = [
      /(\b(?:Authorization|X-Chi-Bridge):\s*(?:Bearer\s+|Basic\s+|Token\s+)?)[^\s"'`]+/i,
      /((?<![A-Za-z0-9])[A-Za-z0-9_-]*?(?:token|api[_-]?key|access[_-]?key|secret|password|passwd)["']?\s*[=:]\s*["']?)[^\s"'&`,;}]+/i,
      # A URL's password: scheme://user:PASSWORD@host.
      %r{(\b[a-z][a-z0-9+.-]*://[^/\s:@]+:)[^@\s/]+(?=@)}i
    ].freeze
    # A text that ends where one of VALUES' values (or a private key's
    # BEGIN line) would go on: a stream cut there would send the value
    # on its own, unredacted (ParticipantStreamFilter never cuts there).
    OPEN_VALUE = /(?:\b(?:Authorization|X-Chi-Bridge):\s*(?:(?:Bearer|Basic|Token)\s*)?|[A-Za-z0-9_-]*?(?:token|api[_-]?key|access[_-]?key|secret|password|passwd)["']?\s*(?:[=:]\s*["']?)?|-----BEGIN [A-Z0-9 ]*)\z/i

    module_function

    # +value+ with every string in it redacted (hash values, array items).
    def deep(value, viewer)
      case value
      when String then text(value, viewer)
      when Hash then value.transform_values { |item| deep(item, viewer) }
      when Array then value.map { |item| deep(item, viewer) }
      else value
      end
    end

    def text(value, viewer)
      out = value.dup
      viewer.secrets.each { |secret| out = out.gsub(secret, MARK) }
      PATTERNS.each { |pattern| out = out.gsub(pattern, MARK) }
      VALUES.each { |pattern| out = out.gsub(pattern) { "#{Regexp.last_match(1)}#{MARK}" } }
      out = within(out, viewer.cwd.to_s)
      home = viewer.home.to_s
      out = out.gsub(%r{#{Regexp.escape(home)}(?=/|\b|\z)}, "~") if home.length > 1
      out
    end

    # +text+ with +dir+ (the session's folder) shown relative: "dir/x"
    # as "x", "dir" alone as ".".
    def within(text, dir)
      return text if dir.length < 2

      text.gsub(%r{#{Regexp.escape(dir)}(/|(?=\b|\z))}) { Regexp.last_match(1) == "/" ? "" : "." }
    end
  end
end
