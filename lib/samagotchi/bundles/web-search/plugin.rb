# frozen_string_literal: true

# The web-search bundle (docs/bundles.md, The web-search bundle): one tool,
# web_search, that asks a SearXNG instance through its JSON API and returns
# a short list of results (title, URL, snippet). The model reads the ones it
# wants with web_fetch. The query goes to that SearXNG and on to the engines
# it is configured with.
#
# Settings (config.yml, bundles: web-search:), read at each call from
# ctx.settings, never at load:
#   url: http://127.0.0.1:8888   the SearXNG root (http/https with a host)
#   max_results: 8               results listed, 1..20
#   timeout: 10                  seconds, ctx.http's per-read timeout
#   language: en                 optional, sent only when set
#   safesearch: 0                optional, 0/1/2
#   categories: general          optional, comma-separated
#   engines: duckduckgo,brave    optional, comma-separated (SearXNG drops
#                                names it doesn't know)
#
# SearXNG needs `json` in search.formats (else it answers 403) and, for a
# local instance, server.limiter: false (else it may answer 429).
require "json"
require "uri"

class Plugin
  DEFAULT_URL = "http://127.0.0.1:8888"
  DEFAULT_MAX = 8
  MAX_RESULTS = 20
  DEFAULT_TIMEOUT = 10
  SNIPPET_CHARS = 300
  TIME_RANGES = %w[day week month year].freeze
  # Optional settings sent as query parameters, in this order, only when set.
  OPTIONAL = %w[language safesearch categories engines].freeze

  DESCRIPTION = "Search the web (through the user's SearXNG) and return a numbered list of results: title, URL and " \
                "a short snippet. Snippets are partial and may be stale: when the details matter, read a result's " \
                "URL with web_fetch before answering instead of answering from snippets alone. Use page for more " \
                "results and time_range for recent ones."

  # A setting that can't be used: the tool's answer, before any request.
  class SettingError < StandardError; end

  def initialize(_settings); end

  def register(chi)
    chi.tool "web_search", DESCRIPTION,
             params: {
               query: { type: "string", description: "The search terms", required: true },
               time_range: { type: "string", enum: TIME_RANGES, description: "Only results from the last day, week, month or year" },
               page: { type: "integer", description: "The results page, 1 for the first (the default)" }
             },
             label: "searching", preview: ->(args) { args["query"].to_s } do |args, ctx|
      search(args, ctx)
    end
  end

  private

  def search(args, ctx)
    query = args["query"].to_s.strip
    return "Error: query is required" if query.empty?

    settings = ctx.settings
    root = root_url(settings["url"])
    page = page_of(args["page"])
    res = ctx.http.get("#{root}/search?#{URI.encode_www_form(pairs(query, page, args["time_range"], settings))}",
                       timeout: timeout_of(settings["timeout"]))
    answer(res, query, page, max_of(settings["max_results"]))
  rescue SettingError => e
    "Error: #{e.message}"
  rescue Samagotchi::Plugin::HttpCancelled
    "Error: search cancelled"
  rescue Samagotchi::Plugin::HttpError => e
    "Error: SearXNG is not reachable: #{e.message}. Is it running? (bundles: web-search: url)"
  end

  def answer(res, query, page, max)
    return status_error(res.status) unless res.ok?

    data = begin
      JSON.parse(res.body.scrub)
    rescue JSON::ParserError
      nil
    end
    return "Error: SearXNG's answer isn't JSON (is url the SearXNG root?)" unless data.is_a?(Hash)

    listing(data, query, page, max)
  end

  def status_error(status)
    case status
    when 403 then "Error: SearXNG refused the JSON format (403): add json to search.formats in its settings.yml"
    when 429 then "Error: SearXNG rate-limited the request (429): turn its limiter off for a local instance (server.limiter: false)"
    else "Error: SearXNG answered #{status}"
    end
  end

  def listing(data, query, page, max)
    results = Array(data["results"]).select { |entry| entry.is_a?(Hash) && !squash(entry["url"]).empty? }.first(max)
    if results.empty?
      failed = Array(data["unresponsive_engines"]).map { |pair| squash(Array(pair).first) }.reject(&:empty?)
      return [%(No results for "#{query}".), (failed.empty? ? nil : "Engines that failed: #{failed.join(", ")}")].compact.join("\n")
    end

    lines = [%(SearXNG results for "#{query}" (page #{page}):)]
    if (first = first_answer(data["answers"]))
      lines << "Answer: #{first}"
    end
    results.each_with_index { |entry, index| lines.concat(result_lines(entry, index + 1)) }
    suggestions = Array(data["suggestions"]).map { |text| squash(text) }.reject(&:empty?)
    lines << "Suggestions: #{suggestions.join(", ")}" unless suggestions.empty?
    lines.join("\n")
  end

  def result_lines(entry, number)
    url = squash(entry["url"])
    title = squash(entry["title"])
    snippet = cut(squash(entry["content"]))
    ["#{number}. #{title.empty? ? url : title}", "   #{url}", (snippet.empty? ? nil : "   #{snippet}")].compact
  end

  # answers: Strings (older SearXNG) or Hashes with the text under "answer".
  def first_answer(answers)
    Array(answers).each do |item|
      text = cut(squash(item.is_a?(Hash) ? item["answer"] : item))
      return text unless text.empty?
    end
    nil
  end

  def pairs(query, page, time_range, settings)
    list = [["q", query], %w[format json], ["pageno", page.to_s]]
    list << ["time_range", time_range.to_s] if TIME_RANGES.include?(time_range.to_s)
    OPTIONAL.each do |key|
      value = settings[key]
      list << [key, value.to_s] unless value.nil? || value.to_s.strip.empty?
    end
    list
  end

  def root_url(value)
    url = (value.nil? ? DEFAULT_URL : value.to_s).strip
    uri = URI.parse(url)
    raise SettingError, "bundles: web-search: url must be an http(s) URL" unless %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?

    url.chomp("/")
  rescue URI::InvalidURIError
    raise SettingError, "bundles: web-search: url must be an http(s) URL"
  end

  def page_of(value)
    page = begin
      Integer(value)
    rescue ArgumentError, TypeError, FloatDomainError
      1
    end
    [page, 1].max
  end

  def timeout_of(value) = value.is_a?(Numeric) && value.positive? ? value : DEFAULT_TIMEOUT

  def max_of(value)
    max = begin
      Integer(value)
    rescue ArgumentError, TypeError, FloatDomainError
      DEFAULT_MAX
    end
    max.clamp(1, MAX_RESULTS)
  end

  def squash(value) = value.to_s.scrub.gsub(/\s+/, " ").strip

  def cut(text) = text.length > SNIPPET_CHARS ? "#{text[0, SNIPPET_CHARS - 1]}…" : text
end
