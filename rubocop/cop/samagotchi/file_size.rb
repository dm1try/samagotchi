# frozen_string_literal: true

module RuboCop
  module Cop
    module Samagotchi
      # Keeps Ruby files below their line-count cap; files already over the
      # default cap get a small, shrinking allowance in .rubocop.yml.
      class FileSize < Base
        MSG = "File has %{count} lines, over its cap of %{cap}: split it " \
              "(docs/testing.md, File size); never raise a cap."

        def on_new_investigation
          line_count = processed_source.raw_source.count("\n")
          path = config.path_relative_to_config(processed_source.file_path)
          cap = cop_config.fetch("Caps", {}).fetch(path, cop_config.fetch("Max", 1000))
          return unless line_count > cap

          add_offense(processed_source.buffer.line_range(1),
                      message: format(MSG, count: line_count, cap: cap))
        end
      end
    end
  end
end
