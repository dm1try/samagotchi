# frozen_string_literal: true

require "fileutils"
require "ipaddr"
require "json"
require "net/http"
require "open3"
require "openssl"
require "time"
require "timeout"
require "uri"

# The logic behind `rake deps:check` (Rakefile): what our dependencies did
# since we last looked. Three sections, each read-only and informational:
#
# - engines: each Splash and llama.cpp host in chi's config.yml on a private
#   or loopback address (never a public API), what runs there, and the
#   newest upstream release (GitHub, no auth);
# - Ruby gems: `bundle outdated --only-explicit`;
# - npm: `npm outdated` and `npm audit` advisories.
#
# What a run saw goes to a state file outside the repo (the engines are this
# machine's): the next run marks with NEW what changed since. A section that
# can't be read (offline, a GitHub rate limit) says why and the run goes on.
# Kept out of lib/ (not shipped) and free of Rake so the specs can call it.
# See docs/testing.md ("Dependency check").
module DepsCheck
  SPLASH_REPO = "incoai/splash"
  LLAMA_REPO = "ggml-org/llama.cpp"
  REPOS = { "splash" => SPLASH_REPO, "llama.cpp" => LLAMA_REPO }.freeze
  PROBE_TIMEOUT = 2
  GITHUB_TIMEOUT = 10
  STATE_ENV = "DEPS_CHECK_STATE"
  SPLASH_VERSION_TASK = 'rake "deps:splash_version[X.Y.Z]"'
  # Host names taken as on this machine or its LAN without a DNS lookup.
  LAN_SUFFIXES = %w[.local .lan .internal .home.arpa].freeze

  # A config.yml hosts: entry, as far as the check needs it.
  Host = Data.define(:name, :host, :port, :scheme, :api) do
    def address = "#{host}:#{port}"
    def base_url = "#{scheme}://#{host.include?(":") ? "[#{host}]" : host}:#{port}"
  end

  class Error < StandardError; end

  module_function

  # --- entry points -------------------------------------------------------

  # The report as text (format nil) or JSON ("json"); writes the state file.
  def check(root, format: nil, hosts: config_hosts, state_path: self.state_path, now: Time.now)
    previous = load_state(state_path)
    report = build_report(root, hosts: hosts, previous: previous, now: now)
    save_state(state_path, next_state(report, previous))
    format == "json" ? JSON.pretty_generate(report) : render(report)
  end

  # Records the Splash version the user read on the engine host, with the
  # build_id its /status shows now: every Splash host in the config, or the
  # one given as host:port. Returns the lines to print.
  #
  # Stopgap until Splash's /status carries its version (upstream ask:
  # incoai/splash, "version in /status"); remove this and the recorded
  # version once a Splash release has it.
  def record_splash_version(version, address: nil, hosts: config_hosts, state_path: self.state_path)
    raise Error, "not a version: #{version.inspect}" unless version.to_s.match?(/\A\d+(\.\d+)+\z/)

    candidates = probe_targets(hosts)
    candidates = candidates.select { |h| h.address == address } if address
    raise Error, "no hosts entry on a private address is #{address}" if address && candidates.empty?

    state = load_state(state_path)
    engines = (state["engines"] ||= {})
    lines = candidates.filter_map do |host|
      engine = probe(host)
      next unless engine[:kind] == "splash"

      entry = (engines[host.address] ||= {})
      entry.merge!("kind" => "splash", "version" => version.to_s, "version_build_id" => engine[:build_id])
      "splash #{host.address}: recorded #{version} (build #{short_build(engine[:build_id])})"
    end
    raise Error, "no Splash host answered /status#{" on #{address}" if address}" if lines.empty?

    save_state(state_path, state)
    lines
  end

  # --- hosts --------------------------------------------------------------

  # The hosts: entries of chi's config.yml (ConfigFile.hosts_config, what
  # Config.load! reads them with), loaded on demand: a rake task that
  # doesn't check deps never loads chi's config.
  def config_hosts
    require_relative "../../lib/samagotchi/host_config"
    Samagotchi::ConfigFile.hosts_config.values.map do |h|
      Host.new(name: h.name, host: h.host, port: h.port, scheme: h.scheme, api: h.api&.to_s)
    end
  end

  # The hosts worth a probe: on a loopback or private address, each address
  # once (two entries can share a server).
  def probe_targets(hosts) = hosts.select { |h| local_host?(h.host) }.uniq(&:address)

  # A loopback, private or link-local IP, localhost, a single-label name or
  # a LAN suffix. Any other name counts as public (no DNS lookup: the check
  # must not depend on the resolver, and never probes a public API).
  def local_host?(name)
    name = name.to_s.downcase.delete_prefix("[").delete_suffix("]")
    return true if name == "localhost" || name.end_with?(".localhost")

    ip = IPAddr.new(name)
    ip.loopback? || ip.private? || ip.link_local?
  rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
    !name.include?(".") || LAN_SUFFIXES.any? { |suffix| name.end_with?(suffix) }
  end

  # What runs on +host+: llama.cpp (/props with build_info), Splash
  # (/status with identity and chat_template), :other (answers, neither), or
  # down (no answer).
  def probe(host)
    props = answer("#{host.base_url}/props")
    if props.is_a?(Hash) && props["build_info"]
      model = props["model_path"] || props.dig("default_generation_settings", "model")
      return { kind: "llama.cpp", status: "up", build_info: props["build_info"].to_s,
               model: model && File.basename(model.to_s) }
    end

    status = answer("#{host.base_url}/status")
    if status.is_a?(Hash) && status.key?("identity") && status.key?("chat_template")
      return { kind: "splash", status: "up", build_id: status.dig("identity", "cache", "build_id"),
               model: status.dig("instance", "model") }
    end

    { kind: nil, status: "other" }
  rescue SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, SocketError
    { kind: nil, status: "down" }
  end

  # A probe's JSON, or nil when the server answers with an error status or
  # not JSON (a 404 on the other engine's endpoint); no answer raises.
  def answer(url)
    get_json(url, timeout: PROBE_TIMEOUT)
  rescue Error
    nil
  end

  # --- upstream releases --------------------------------------------------

  # The newest release of +kind+'s repo: { tag:, date:, url: }. Splash: the
  # newest that isn't a draft or a pre-release. llama.cpp marks every b<N>
  # build a pre-release, so /releases/latest has none: the newest b<N> tag.
  def upstream(kind)
    repo = REPOS.fetch(kind)
    list = get_json("https://api.github.com/repos/#{repo}/releases?per_page=#{kind == "splash" ? 10 : 5}",
                    timeout: GITHUB_TIMEOUT, headers: { "Accept" => "application/vnd.github+json" })
    raise Error, "GitHub: unexpected reply for #{repo}" unless list.is_a?(Array)

    release = list.find do |r|
      next false if r["draft"]

      kind == "splash" ? !r["prerelease"] : r["tag_name"].to_s.match?(/\Ab\d+\z/)
    end
    raise Error, "GitHub: no release found for #{repo}" unless release

    { tag: release["tag_name"], date: release["published_at"].to_s[0, 10], url: release["html_url"] }
  end

  def get_json(url, timeout:, headers: {})
    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = timeout
    http.read_timeout = timeout
    request = Net::HTTP::Get.new(uri, { "User-Agent" => "samagotchi-deps-check" }.merge(headers))
    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      limited = %w[403 429].include?(response.code)
      raise Error, "#{uri.host}: HTTP #{response.code}#{" (rate limit?)" if limited && uri.host == "api.github.com"}"
    end

    JSON.parse(response.body.to_s)
  rescue JSON::ParserError
    raise Error, "#{uri.host}: not JSON"
  end

  # --- the report ---------------------------------------------------------

  def build_report(root, hosts:, previous:, now:)
    {
      "checked_at" => now.utc.iso8601,
      "previous_checked_at" => previous["checked_at"],
      "engines" => engines_section(hosts, previous),
      "gems" => gems_section(root, previous),
      "npm" => npm_section(root, previous)
    }
  end

  def engines_section(hosts, previous)
    seen = previous["engines"] || {}
    probed = probe_targets(hosts).map { |host| [host, probe(host)] }
    rows = probed.filter_map do |host, engine|
      last = seen[host.address] || {}
      next if engine[:status] == "other"

      # A host that doesn't answer: the kind it had last time, else what its
      # api says (no api: is llama.cpp's own API).
      kind = engine[:kind] || last["kind"] || (host.api.nil? || host.api == "llama_cpp" ? "llama.cpp" : nil)
      [host, engine, kind, last]
    end

    upstreams = {}
    errors = []
    rows.map { |row| row[2] }.compact.uniq.sort.each do |kind|
      upstreams[kind] = upstream(kind)
    rescue Error, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError, SocketError => e
      errors << "upstream #{kind}: #{e.message}"
    end

    list = rows.map do |host, engine, kind, last|
      engine_row(host, engine, kind, last, upstreams[kind], previous.dig("upstream", kind))
    end
    { "hosts" => new_first(list), "upstream" => upstreams.transform_keys(&:to_s).transform_values { |u| stringify(u) },
      "errors" => errors }
  end

  def engine_row(host, engine, kind, last, up, last_up)
    row = { "name" => host.name, "address" => host.address, "kind" => kind, "status" => engine[:status] }
    if engine[:status] == "up"
      row["model"] = engine[:model]
      row["build_info"] = engine[:build_info] if kind == "llama.cpp"
      row["build_id"] = engine[:build_id] if kind == "splash"
    else
      row["last_seen"] = last["build_info"] || last["version"]
    end
    if kind == "splash"
      row["recorded_version"] = last["version"]
      row["version_build_id"] = last["version_build_id"]
      row["build_changed"] = !!(last["version"] && engine[:build_id] && last["version_build_id"] != engine[:build_id])
    end
    if up
      row["upstream"] = stringify(up)
      behind = builds_behind(engine[:build_info], up[:tag]) if kind == "llama.cpp"
      row["builds_behind"] = behind if behind
    end
    row["new"] = engine_fingerprint(row, last, row["upstream"] ? row["upstream"]["tag"] : last_up&.dig("tag")) !=
                 engine_fingerprint_was(last, last_up)
    row
  end

  # What a NEW engine line compares: what runs there and the upstream tag.
  # A run whose GitHub call failed compares with the last tag it had.
  def engine_fingerprint(row, last, tag)
    if row["status"] == "up"
      [row["kind"], "up", row["model"], row["build_info"] || row["build_id"], row["recorded_version"], tag]
    else
      [row["kind"], "down", nil, last["build_info"] || last["build_id"], last["version"], tag]
    end
  end

  def engine_fingerprint_was(last, last_up)
    return nil if last.empty?

    [last["kind"], last["status"], last["status"] == "up" ? last["model"] : nil,
     last["build_info"] || last["build_id"], last["version"], last_up&.dig("tag")]
  end

  def builds_behind(build_info, tag)
    mine = build_info.to_s[/\Ab(\d+)/, 1] or return nil
    newest = tag.to_s[/\Ab(\d+)\z/, 1] or return nil
    [newest.to_i - mine.to_i, 0].max
  end

  # `bundle outdated --only-explicit --parseable`: exit 1 just means
  # something is outdated; a line it can't parse is progress noise.
  def gems_section(root, previous)
    out, err, status = run_command(%w[bundle outdated --only-explicit --parseable], root)
    gems = out.lines.filter_map do |line|
      m = line.match(/\A(\S+) \(newest ([^,]+), installed ([^,)]+)(?:, requested ([^)]+))?\)/) or next
      { "name" => m[1], "current" => m[3], "newest" => m[2], "requested" => m[4] }
    end
    if gems.empty? && !status.success?
      return { "outdated" => [], "error" => "bundle outdated failed: #{first_line(err, out)}" }
    end

    seen = previous["gems"] || {}
    gems.each { |g| g["new"] = seen[g["name"]] != g["newest"] }
    { "outdated" => new_first(gems.sort_by { |g| g["name"] }), "error" => nil }
  rescue SystemCallError => e
    { "outdated" => [], "error" => "bundle outdated: #{e.message}" }
  end

  # `npm outdated --json` and `npm audit --json` exit non-zero when they
  # find something: only output that isn't JSON is an error.
  def npm_section(root, previous)
    section = { "outdated" => [], "advisories" => [], "errors" => [] }
    seen = previous["npm"] || {}
    begin
      data = npm_json(%w[npm outdated --json], root)
      section["outdated"] = new_first(data.sort.map do |name, info|
        { "name" => name, "current" => info["current"], "wanted" => info["wanted"], "latest" => info["latest"],
          "new" => seen[name] != info["latest"] }
      end)
    rescue Error, SystemCallError => e
      section["errors"] << "npm outdated: #{e.message}"
    end
    begin
      section["advisories"] = new_first(advisories(npm_json(%w[npm audit --json], root), previous["advisories"] || []))
    rescue Error, SystemCallError => e
      section["errors"] << "npm audit: #{e.message}"
    end
    section
  end

  def npm_json(argv, root)
    out, err, = run_command(argv, root)
    data = out.strip.empty? ? {} : JSON.parse(out)
    raise Error, data["error"]["summary"].to_s if data.is_a?(Hash) && data["error"].is_a?(Hash)
    raise Error, "unexpected output" unless data.is_a?(Hash)

    data
  rescue JSON::ParserError
    raise Error, first_line(err, out)
  end

  # npm audit's vulnerabilities: one row per advisory (its GHSA url as the
  # id), with the package and severity; most severe first.
  def advisories(audit, seen_ids)
    order = %w[critical high moderate low info]
    rows = (audit["vulnerabilities"] || {}).flat_map do |package, vuln|
      Array(vuln["via"]).grep(Hash).map do |via|
        id = via["url"] || via["source"].to_s
        { "id" => id, "package" => package, "severity" => via["severity"] || vuln["severity"],
          "title" => via["title"], "url" => via["url"], "new" => !seen_ids.include?(id) }
      end
    end
    rows.uniq { |r| [r["id"], r["package"]] }
        .sort_by { |r| [order.index(r["severity"]) || order.size, r["package"], r["id"]] }
  end

  def run_command(argv, root) = Open3.capture3(*argv, chdir: root)

  # --- state --------------------------------------------------------------

  def state_path(env: ENV)
    return env[STATE_ENV] unless env[STATE_ENV].to_s.empty?

    base = env["XDG_STATE_HOME"].to_s.empty? ? File.join(Dir.home, ".local", "state") : env["XDG_STATE_HOME"]
    File.join(base, "samagotchi", "deps-check.json")
  end

  def load_state(path)
    data = File.file?(path) ? JSON.parse(File.read(path)) : {}
    data.is_a?(Hash) ? data : {}
  rescue JSON::ParserError
    {}
  end

  def save_state(path, state)
    FileUtils.mkdir_p(File.dirname(path))
    tmp = "#{path}.#{Process.pid}.tmp"
    File.write(tmp, "#{JSON.pretty_generate(state)}\n")
    File.rename(tmp, path)
  end

  # The state the next run compares with. An engine that is down keeps what
  # it had; a recorded Splash version stays until the user records another;
  # an upstream that failed keeps its last tag.
  def next_state(report, previous)
    engines = (previous["engines"] || {}).transform_values(&:dup)
    report["engines"]["hosts"].each do |row|
      entry = (engines[row["address"]] ||= {})
      entry["kind"] = row["kind"] if row["kind"]
      entry["status"] = row["status"]
      next unless row["status"] == "up"

      entry["model"] = row["model"]
      %w[build_info build_id].each { |key| row[key] ? entry[key] = row[key] : entry.delete(key) }
    end
    upstream = (previous["upstream"] || {}).merge(report["engines"]["upstream"])
    gems = if report["gems"]["error"]
             previous["gems"] || {}
           else
             report["gems"]["outdated"].to_h { |g| [g["name"], g["newest"]] }
           end
    npm_failed = report["npm"]["errors"].any? { |e| e.start_with?("npm outdated") }
    audit_failed = report["npm"]["errors"].any? { |e| e.start_with?("npm audit") }
    {
      "checked_at" => report["checked_at"],
      "engines" => engines,
      "upstream" => upstream,
      "gems" => gems,
      "npm" => npm_failed ? previous["npm"] || {} : report["npm"]["outdated"].to_h { |n| [n["name"], n["latest"]] },
      "advisories" => audit_failed ? previous["advisories"] || [] : report["npm"]["advisories"].map { |a| a["id"] }.uniq
    }
  end

  # --- text ---------------------------------------------------------------

  def render(report)
    since = report["previous_checked_at"] ? "NEW = changed since #{report["previous_checked_at"]}" : "first run: all NEW"
    out = ["deps:check #{report["checked_at"]} (#{since})", "", "Engines"]
    engines = report["engines"]
    out += engines["hosts"].flat_map { |row| engine_lines(row) }
    out << "    no Splash or llama.cpp host on a private address in config.yml" if engines["hosts"].empty?
    out += engines["errors"].map { |e| "    #{e}" }

    out += ["", "Ruby gems (bundle outdated, direct)"]
    gems = report["gems"]
    out << "    #{gems["error"]}" if gems["error"]
    out += gems["outdated"].map do |g|
      line("#{g["name"]} #{g["current"]} → #{g["newest"]}#{" (Gemfile #{g["requested"]})" if g["requested"]}", g["new"])
    end
    out << "    all up to date" if gems["outdated"].empty? && !gems["error"]

    out += ["", "npm (outdated, direct; audit)"]
    npm = report["npm"]
    out += npm["errors"].map { |e| "    #{e}" }
    out += npm["outdated"].map do |n|
      wanted = n["wanted"] == n["latest"] ? "" : " (wanted #{n["wanted"]})"
      line("#{n["name"]} #{n["current"]} → #{n["latest"]}#{wanted}", n["new"])
    end
    out += npm["advisories"].map do |a|
      line("advisory #{a["severity"]}: #{a["package"]} · #{a["title"]} #{a["url"]}".rstrip, a["new"])
    end
    audit_ok = npm["errors"].none? { |e| e.start_with?("npm audit") }
    out << "    audit: no advisories" if audit_ok && npm["advisories"].empty?
    "#{out.join("\n")}\n"
  end

  def engine_lines(row)
    label = "#{row["kind"] || "engine"} #{row["address"]}"
    parts = []
    if row["status"] == "up"
      case row["kind"]
      when "llama.cpp" then parts << row["build_info"]
      when "splash" then parts << (row["recorded_version"] ? "recorded #{row["recorded_version"]}" : "version unknown")
      end
      parts << row["model"] if row["model"]
    else
      parts << "down, skipped#{" (last seen #{row["last_seen"]})" if row["last_seen"]}"
    end
    if (up = row["upstream"])
      behind = row["builds_behind"] ? ", #{row["builds_behind"]} builds behind" : ""
      parts << "upstream #{up["tag"]} (#{up["date"]})#{behind} #{up["url"]}"
    end
    lines = [line("#{label}  #{parts.join(" · ")}", row["new"])]
    if row["kind"] == "splash" && row["status"] == "up"
      if row["build_changed"]
        lines << "      Splash on #{row["address"]} changed build since you recorded #{row["recorded_version"]}: " \
                 "confirm with `splash --version` and record it (#{SPLASH_VERSION_TASK})"
      elsif !row["recorded_version"]
        lines << "      read it with `splash --version` on that host and record it: #{SPLASH_VERSION_TASK}"
      end
    end
    lines
  end

  def line(text, new) = "#{new ? "NEW" : "   "} #{text}"

  # --- helpers ------------------------------------------------------------

  def new_first(rows) = rows.partition { |r| r["new"] }.flatten(1)

  def stringify(hash) = hash&.transform_keys(&:to_s)

  def short_build(build_id) = build_id ? build_id.to_s.delete_prefix("src-")[0, 12] : "unknown"

  def first_line(*texts)
    texts.map(&:to_s).flat_map(&:lines).map(&:strip).find { |l| !l.empty? } || "no output"
  end
end
