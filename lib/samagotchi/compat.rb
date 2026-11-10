# frozen_string_literal: true

require "rubygems/version"
require_relative "version"

module Samagotchi
  # The compatibility decision for state and bridge data from a chi version.
  module Compat
    module_function

    def verdict(worker_version:, version: VERSION, worker_protocol: nil, protocol: nil)
      return :refused if protocol && worker_protocol.to_i > protocol

      worker_version = worker_version.to_s
      version = version.to_s
      return :restart_suggested if worker_version.empty? || version.empty?
      return :restart_suggested unless Gem::Version.correct?(worker_version) && Gem::Version.correct?(version)

      worker = Gem::Version.new(worker_version)
      current = Gem::Version.new(version)
      return :restart_suggested if worker < previous_minor(current)

      :ok
    end

    def previous_minor(version)
      major, minor = version.segments.first(2)
      Gem::Version.new("#{major}.#{[(minor || 0) - 1, 0].max}.0")
    end
    private_class_method :previous_minor
  end
end
