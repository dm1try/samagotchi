# frozen_string_literal: true

require_relative "../log"

module Samagotchi
  module Web
    # web.editor: the URL a ref's click opens in this machine's editor, as a
    # template with {path} (the file's absolute path, each segment encoded
    # by the page) and an optional {line}. A preset name, or a template of
    # one's own; "none" (or an unknown name) turns refs off.
    module Editor
      PRESETS = {
        "vscode" => "vscode://file{path}:{line}",
        "vscode-insiders" => "vscode-insiders://file{path}:{line}",
        "cursor" => "cursor://file{path}:{line}",
        "zed" => "zed://file{path}:{line}"
      }.freeze
      NONE = "none"

      module_function

      # @param value [String, nil] the web.editor setting
      # @return [String, nil] the URL template; nil for none. A value that
      #   is neither a preset nor has {path} logs a warning and is none.
      def template(value)
        text = value.to_s.strip
        return text if text.include?("{path}")

        name = text.downcase
        return nil if name.empty? || name == NONE
        return PRESETS[name] if PRESETS.key?(name)

        Log.warn(:web, "editor_unknown", value: text)
        nil
      end
    end
  end
end
