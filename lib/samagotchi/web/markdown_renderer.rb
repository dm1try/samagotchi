# frozen_string_literal: true

require "nokogiri"
require "uri"

module Samagotchi
  module Web
    class MarkdownRenderer
      WARNING = "Markdown rendering is enabled, but the optional commonmarker gem is not installed. Install it with: gem install commonmarker"
      # NOTE: `span` is allowed because the syntax highlighter (commonmarker/syntect)
      # emits classed <span>s; keeping it lets highlighting render.
      ALLOWED_ELEMENTS = %w[a blockquote br code del em h1 h2 h3 h4 h5 h6 hr li ol p pre s strong span table tbody td th thead tr ul].freeze
      DROP_ELEMENTS = %w[iframe object script style svg].freeze
      ALLOWED_PROTOCOLS = %w[http https mailto].freeze

      def initialize(enabled: false)
        @enabled = enabled
      end

      def enabled?
        @enabled
      end

      def available?
        enabled? && load_bundled_commonmarker!
      end

      def warning
        WARNING if enabled? && !load_bundled_commonmarker!
      end

      def render(markdown)
        return nil unless available?

        html = Commonmarker.to_html(markdown.to_s, options: {
          render: { escape: true }, # escape raw HTML from source; highlighter output is still emitted
          extension: { header_ids: nil }
        }, plugins: {
          # An empty theme makes syntect emit scope classes (`keyword`, `string`, ...)
          # instead of inline colours from one fixed theme, so the page's light and
          # dark palettes colour code blocks (the --code-* tokens in index.html).
          syntax_highlighter: { theme: "" }
        })
        return nil unless html

        sanitize(html)
      end

      private

      def load_bundled_commonmarker!
        return @commonmarker_available unless @commonmarker_available.nil?

        require "commonmarker"
        @commonmarker_available = true
      rescue LoadError
        @commonmarker_available = false
      end

      def sanitize(html)
        fragment = Nokogiri::HTML5.fragment(html)
        fragment.traverse do |node|
          next unless node.element?

          if DROP_ELEMENTS.include?(node.name)
            node.remove
          elsif !ALLOWED_ELEMENTS.include?(node.name)
            node.replace(node.children)
          else
            sanitize_attributes(node)
          end
        end
        fragment.to_html
      end

      def sanitize_attributes(node)
        node.attribute_nodes.each do |attribute|
          next if allowed_attribute?(node, attribute.name)

          node.remove_attribute(attribute.name)
        end
        prefix_highlight_classes(node) if node.name == "span"
        return unless node.name == "a"

        href = node["href"].to_s.strip
        unless safe_href?(href)
          node.remove_attribute("href")
          return
        end
        node["target"] = "_blank"
        node["rel"] = "noopener noreferrer"
      end

      # The syntax highlighter emits `class=` on <pre> ("syntax-highlighting") and
      # <span> (syntect scope names). They come from the highlighter, not user input:
      # raw HTML from the markdown source is already escaped by commonmarker
      # (escape: true), so class attributes are safe to keep on these elements only.
      def allowed_attribute?(node, name)
        return true if name == "class" && %w[span pre].include?(node.name)

        node.name == "a" && %w[href title].include?(name)
      end

      # Scope names are plain words ("diff", "meta", "name", ...) that page CSS and
      # querySelectors use too: prefix them so they only ever match the hl-* rules.
      def prefix_highlight_classes(node)
        words = node["class"].to_s.split
        return node.remove_attribute("class") if words.empty?

        node["class"] = words.map { |word| "hl-#{word}" }.join(" ")
      end

      def safe_href?(href)
        return true if href.start_with?("#", "/")

        uri = URI.parse(href)
        uri.scheme && ALLOWED_PROTOCOLS.include?(uri.scheme.downcase)
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
