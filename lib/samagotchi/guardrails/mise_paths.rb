# frozen_string_literal: true

require_relative "path_resolve"

module Samagotchi
  module Guardrails
    # mise's file names, in one place for the boundaries that judge them:
    # its local files hold secrets (ReviewPaths' SECRET_FILE / SECRET_PATH,
    # PairBoundary's SECRET_TEXT) and its config runs at the owner's next
    # worker start (PairCommand's mise config writes, ProjectEnv).
    module MisePaths
      # A local file's name: mise.local.toml, .mise.dev.local.toml (a
      # Regexp source, to be embedded under the embedding pattern's flags).
      LOCAL_FILE = '\.?mise(?:\.[\w-]+)?\.local\.toml'
      # A local file in mise's config dirs: .config/mise/config.local.toml,
      # config.<env>.local.toml; mise/ and .mise/ too (a Regexp source).
      LOCAL_DIR_FILE = '(?:\.config/mise|\.?mise)/config(?:\.[\w-]+)?\.local\.toml'

      # mise's config files, by a path's end: mise.toml, .mise.toml,
      # mise.<env>.toml, .config/mise.toml, anything under .config/mise/,
      # mise/ or .mise/ config*.toml, and the .tool-versions it reads too.
      CONFIG_PATH = %r{(?:\A|/)(?:\.?mise(?:\.[^/]+)?\.toml|\.config/mise\.toml|\.config/mise/.+|
                       \.?mise/config[^/]*\.toml|\.tool-versions)\z}x
      # The same files named in a command's or script's text.
      CONFIG_TEXT = %r{(?<![\w-])(?:\.?mise(?:\.[\w.-]+)?\.toml|\.config/mise|\.?mise/config[\w.-]*\.toml|
                      \.tool-versions(?![\w.-]))}x

      # Whether +path+ is one of mise's config files (CONFIG_PATH), as
      # given or as it resolves.
      def self.config?(path)
        path.to_s.match?(CONFIG_PATH) ||
          (path.to_s.start_with?("/") && PathResolve.reals(path).any? { |real| real.match?(CONFIG_PATH) })
      end
    end
  end
end
