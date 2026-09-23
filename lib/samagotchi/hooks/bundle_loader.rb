# frozen_string_literal: true

require_relative "registry"
require "digest"

module Samagotchi
  # Namespace that wraps hook plugin classes per-bundle. Each bundle's hooks are
  # evaluated inside `Samagotchi::Bundles::<BundleName>` so that two bundles
  # shipping a file with the same basename (e.g. `guardrails.rb`) cannot collide
  # on a top-level constant.
  module Bundles; end

  module Hooks
    # Loads bundle-owned hook plugins into a Registry.
    #
    # Unlike +Hooks::Loader+ (which `require`s a file and resolves a top-level
    # constant), this loader `module_eval`s each plugin file inside a
    # per-bundle namespace module. This gives:
    #   - zero class-name collisions across bundles
    #   - a clean uninstall path (`Registry#unregister_bundle`)
    #
    # Each plugin must define a class whose PascalCase name matches the file
    # basename and whose instances respond to +call(event)+.
    #
    # A "fail_closed" before_tool_call hook is required: if it is missing,
    # fails to load, or its file's sha256 differs from the one recorded at
    # install, the failure is reported and the gate denies every tool call.
    # Any hook whose sha256 differs is not loaded (reinstall the bundle
    # after editing a hook by hand).
    #
    # The +on_error+ policy is applied per hook at fire time:
    #   - "fail_closed" (on :before_tool_call): a raising guardrail sets
    #     event[:blocked] = true — the tool call is prevented (fail-closed).
    #   - "log": warn to stderr and continue.
    #   - "skip" (default): silently continue.
    module BundleLoader
      class << self
        # Load all hook plugins for a bundle into the given registry.
        #
        # @param bundle_name [String]
        # @param hooks_dir [String] directory containing the bundle's .rb hook files
        # @param metadata [Hash] basename => { event:, on_error:, priority: }
        # @param registry [Samagotchi::Hooks::Registry]
        # @param failures [Guardrails::LoadFailures, nil] collects hooks that
        #   failed to load
        # @return [Integer] number of hooks successfully registered
        def load(bundle_name:, hooks_dir:, metadata:, registry:, failures: nil)
          return 0 unless metadata.is_a?(Hash)

          loaded = 0
          metadata.each do |raw_basename, raw_meta|
            basename = raw_basename.to_s
            next if basename.empty?

            meta = ->(key) { raw_meta && (raw_meta[key] || raw_meta[key.to_s]) }
            event = meta.(:event).to_s
            # A hook with no declared event cannot be auto-registered.
            next if event.empty?

            event_sym = event.to_sym
            on_error = (meta.(:on_error) || "skip").to_s
            priority = (meta.(:priority) || 100).to_i
            fail_closed = on_error == "fail_closed" && event_sym == :before_tool_call
            what = "hook #{basename} (bundle #{bundle_name})"
            file = hooks_dir && File.join(hooks_dir, basename)
            unless file && File.exist?(file)
              failures&.add(what, "the file is missing", required: true) if fail_closed
              next
            end
            if (mismatch = sha_mismatch(file, meta.(:sha256), required: fail_closed))
              warn "[samagotchi:hooks] bundle '#{bundle_name}' hook '#{basename}' not loaded: #{mismatch}"
              failures&.add(what, mismatch, required: fail_closed)
              next
            end

            begin
              plugin = instantiate(bundle_name, basename, file)

              registry.register_bundle(bundle_name, event_sym, hook_name: basename, priority: priority) do |event|
                begin
                  plugin.call(event)
                rescue Exception => e
                  handle_error(bundle_name, basename, on_error, fail_closed, event, e)
                end
              end
              loaded += 1
            rescue Exception => e
              warn "[samagotchi:hooks] bundle '#{bundle_name}' hook '#{basename}' failed to load: #{e.class}: #{e.message}"
              failures&.add(what, "#{e.class}: #{e.message}", required: fail_closed)
            end
          end
          loaded
        end

        # Why the file doesn't match the sha256 recorded at install, or nil.
        # With none recorded, only a required hook counts as a mismatch.
        def sha_mismatch(file, recorded, required:)
          expected = recorded.to_s.sub(/\Asha256:/, "")
          return (required ? "no sha256 recorded for it (reinstall the bundle)" : nil) if expected.empty?

          actual = Digest::SHA256.hexdigest(File.binread(file))
          return nil if actual == expected

          "its sha256 #{actual[0, 12]}… differs from the installed #{expected[0, 12]}… (edited after install? reinstall the bundle)"
        end

        # Evaluate a plugin file inside the bundle's namespace module and
        # return an instance that responds to #call.
        def instantiate(bundle_name, basename, file)
          ns = namespace_for(bundle_name)
          content = File.read(file)
          ns.module_eval(content, file, 1)
          class_name = File.basename(basename, ".rb").split("_").map(&:capitalize).join
          klass = ns.const_get(class_name, false)
          instance = klass.new
          raise ArgumentError, "plugin #{class_name} does not respond to #call" unless instance.respond_to?(:call)
          instance
        end

        # The (lazily created) namespace module for a bundle.
        # Sanitization is made injective by appending a short digest so that
        # `my-bundle` and `my_bundle` do not collide.
        def namespace_for(bundle_name)
          raw = bundle_name.to_s
          base = raw.gsub(/[^A-Za-z0-9_]/, "_")
          base = "B_#{base}" unless base.match?(/\A[A-Z]/)
          digest = Digest::MD5.hexdigest(raw)[0, 4]
          ns_name = "#{base}_#{digest}"
          if Samagotchi::Bundles.const_defined?(ns_name.to_sym, false)
            Samagotchi::Bundles.const_get(ns_name.to_sym)
          else
            Samagotchi::Bundles.const_set(ns_name.to_sym, Module.new)
          end
        end

        # Apply the per-hook on_error policy when a plugin raises.
        def handle_error(bundle_name, basename, on_error, fail_closed, event, error)
          if fail_closed && event.is_a?(Hash)
            event[:blocked] = true
            reason = "guardrail #{basename} (bundle #{bundle_name}) failed: #{error.class}: #{error.message}"
            event[:guardrail]&.deny!(reason, rule: "guardrail-load", source: "core", decided_by: "core")
            existing = event[:block_reason].to_s
            event[:block_reason] = existing.empty? ? reason : "#{existing}; #{reason}"
          elsif on_error == "log"
            warn "[samagotchi:hooks] #{basename} (bundle #{bundle_name}) failed: #{error.class}: #{error.message}"
          end
          # "skip" (and fail_closed on non-veto events) is silent.
        end
      end
    end
  end
end
