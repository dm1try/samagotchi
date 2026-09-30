# frozen_string_literal: true
require_relative "memory_bundle/manifest"
require_relative "memory_bundle/source"
require_relative "memory_bundle/provenance"
require_relative "memory_bundle/placeholder"
require_relative "memory_bundle/index_updater"
require_relative "memory_bundle/merger"
require_relative "memory_bundle/installer"
require_relative "memory_bundle/uninstaller"
require_relative "memory_bundle/status"
require_relative "memory_bundle/system_bundle"
require_relative "memory_bundle/builder"
require_relative "memory_bundle/listing"
require_relative "memory_bundle/profile"
module Samagotchi
  # Namespace for shareable memory bundle functionality.
  module MemoryBundle; end
end
