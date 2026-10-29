# frozen_string_literal: true

require_relative "../plugin/api"

module Samagotchi
  module Testing
    # One chi.* call a plugin's #register made, as made: its arguments
    # before Plugin::Api checks and normalizes them (params: as given).
    Declaration = Data.define(:name, :args, :options)

    # The real Plugin::Api, also recording each declaration in order
    # (#declarations), for a spec of what #register declares as written.
    class RecordingApi < Plugin::Api
      DECLARATIONS = %i[command annotation tool on service init toolkit tool_source peer_source prompt_section].freeze

      # @return [Array<Declaration>]
      def declarations = (@declarations ||= [])

      DECLARATIONS.each do |name|
        define_method(name) do |*args, **options, &block|
          declarations << Declaration.new(name: name, args: args.freeze, options: options.freeze)
          super(*args, **options, &block)
        end
      end
    end
  end
end
