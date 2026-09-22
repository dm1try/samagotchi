# frozen_string_literal: true

module Samagotchi
  module Tools
    # Normalizes a path argument sent by the model: strips surrounding
    # whitespace and expands a leading `~` (Ruby's File APIs treat it
    # literally, which used to create a `./~/` directory in the cwd).
    # Other paths are returned as-is so relative paths stay relative.
    module ToolPath
      module_function

      def normalize(path)
        path = path.to_s.strip
        path.start_with?("~") ? File.expand_path(path) : path
      end
    end
  end
end
