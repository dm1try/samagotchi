# frozen_string_literal: true

module Samagotchi
  module Web
    # What this web page renders that a notice may stand in for
    # (Engine#hook_notify's fallback_for:). The session and tail JSON carry
    # it as +capabilities+; the page leaves out a notice whose fallback_for
    # names a capability that is true here. +display+: the answer's display
    # is rendered as markdown, so its links are links (web.markdown on and
    # commonmarker installed). A later capability is a new member. (The
    # member hides Object#display, which nothing calls on it.)
    Capabilities = Data.define(:display) do # rubocop:disable Lint/DataDefineOverride
      # @param markdown_renderer [MarkdownRenderer]
      def self.for(markdown_renderer)
        new(display: markdown_renderer.available? == true)
      end
    end
  end
end
