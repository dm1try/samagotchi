# frozen_string_literal: true

module Samagotchi
  module Web
    # What this web page renders that a notice may stand in for
    # (Engine#hook_notify's fallback_for:), and what this viewer can do. The
    # session and tail JSON carry it as +capabilities+; the page leaves out
    # a notice whose fallback_for names a capability that is true here.
    # +display+: the answer's display is rendered as markdown, so its links
    # are links (web.markdown on and commonmarker installed). +editor+: this
    # viewer can open a path in this machine's editor (a viewer on this
    # machine, web.editor not none); per request, the URL template goes next
    # to it as the payload's editor_url. A later capability is a new member.
    # (The member hides Object#display, which nothing calls on it.)
    Capabilities = Data.define(:display, :editor) do # rubocop:disable Lint/DataDefineOverride
      # @param markdown_renderer [MarkdownRenderer]
      # @param editor [Boolean] this request's viewer can open refs
      def self.for(markdown_renderer, editor: false)
        new(display: markdown_renderer.available? == true, editor: editor == true)
      end
    end
  end
end
