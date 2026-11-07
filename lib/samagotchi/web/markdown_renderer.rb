# frozen_string_literal: true

require "nokogiri"
require "uri"
require_relative "../block_renderers"
require_relative "../inline_widgets"

module Samagotchi
  module Web
    class MarkdownRenderer
      WARNING = "Markdown rendering is enabled, but the optional commonmarker gem is not installed. Install it with: gem install commonmarker"
      # The session view's tip while rendering is off (#tip): how to turn it
      # on, the gem first when it isn't installed. Each fits two lines on a
      # phone (390px), hence the short lead and the gem one without config.yml.
      TIP = "Markdown answers: restart chi web with --web-markdown (or web.markdown: true in config.yml)."
      TIP_GEM = "Markdown answers: gem install commonmarker, then restart chi web with --web-markdown."
      # NOTE: `span` is allowed because the syntax highlighter (commonmarker/syntect)
      # emits classed <span>s; keeping it lets highlighting render.
      ALLOWED_ELEMENTS = %w[a blockquote br code del em h1 h2 h3 h4 h5 h6 hr li ol p pre s strong span table tbody td th thead tr ul].freeze
      DROP_ELEMENTS = %w[iframe object script style svg].freeze
      ALLOWED_PROTOCOLS = %w[http https mailto].freeze
      # Both Commonmarker calls take these: the parse that reads the fences has
      # to see the blocks #render's own parse does.
      OPTIONS = {
        render: { escape: true }, # escape raw HTML from source; highlighter output is still emitted
        extension: { header_ids: nil }
      }.freeze

      # A code block as the parse tree has it: its language (nil for an indented
      # block or a bare fence) and its literal, the source between the fences.
      Fence = Data.define(:language, :literal)
      # A JSON string's < > & as \u escapes: the same JSON once parsed.
      JSON_MARKUP = { "<" => "\\u003c", ">" => "\\u003e", "&" => "\\u0026" }.freeze

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

      # The tip while rendering is off, nil when it is on. Whether the gem is
      # installed is read from its gemspec, not by loading it: a server that
      # won't render has no use for the native extension.
      def tip
        return nil if enabled?

        commonmarker_installed? ? TIP : TIP_GEM
      end

      def render(markdown)
        return nil unless available?

        html = Commonmarker.to_html(markdown.to_s, options: OPTIONS, plugins: {
          # An empty theme makes syntect emit scope classes (`keyword`, `string`, ...)
          # instead of inline colours from one fixed theme, so the page's light and
          # dark palettes colour code blocks (the --code-* tokens in index.html).
          syntax_highlighter: { theme: "" }
        })
        return nil unless html

        sanitize(html, fences(markdown.to_s))
      end

      private

      def load_bundled_commonmarker!
        return @commonmarker_available unless @commonmarker_available.nil?

        require "commonmarker"
        @commonmarker_available = true
      rescue LoadError
        @commonmarker_available = false
      end

      def commonmarker_installed?
        return @commonmarker_installed unless @commonmarker_installed.nil?

        @commonmarker_installed = Gem::Specification.find_all_by_name("commonmarker").any?
      end

      # Every code block, in document order: the highlighter drops the language
      # from the HTML, the parse tree has it. [] for a text with no fence: its
      # blocks have no language.
      def fences(markdown)
        return [] unless markdown.include?("```") || markdown.include?("~~~")

        fences = []
        Commonmarker.parse(markdown, options: OPTIONS).walk do |node|
          fences << Fence.new(language: language_of(node.fence_info), literal: node.string_content) if node.type == :code_block
        end
        fences
      end

      def language_of(info)
        word = info.to_s.split.first.to_s.downcase
        word if word.match?(BlockRenderers::LANG)
      end

      # After the walk, which drops every attribute it doesn't know. Blocks and
      # fences pair by position; a count that differs says the two parses
      # disagree, and then no block gets one (it shows as source).
      def mark_languages(fragment, fences)
        blocks = fragment.css("pre")
        return unless blocks.size == fences.size

        blocks.zip(fences) do |pre, fence|
          next unless fence.language

          pre["data-lang"] = fence.language
          mark_widget(pre, fence.literal) if fence.language == InlineWidgets::LANG
        end
      end

      # A chi-ui block carries what the page draws or why it doesn't. The JSON
      # is an attribute value (Nokogiri escapes its quotes), and its < > & are
      # \u escapes, so the HTML holds no model markup even as attribute text.
      def mark_widget(pre, literal)
        widget = InlineWidgets.parse(literal)
        if widget.ok?
          pre["data-widget"] = widget.widget_json.gsub(/[<>&]/, JSON_MARKUP)
        else
          pre["data-widget-error"] = widget.error
        end
        pre["data-widget-lenient"] = "" if widget.lenient?
      end

      def sanitize(html, fences)
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
        mark_languages(fragment, fences)
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
