# frozen_string_literal: true

require_relative "registry"
require "digest"
require_relative "../log"
require_relative "../guardrails/load_failures"
require_relative "../memory_bundle/bundle_hook"
require_relative "../memory_bundle/provenance"
require_relative "../memory_bundle/manifest"
require_relative "../version"

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
    # after editing a hook by hand), nor any of a bundle whose requires_chi
    # this chi doesn't meet.
    #
    # The +on_error+ policy is applied per hook at fire time (Hooks.wrap):
    #   - "fail_closed" (on :before_tool_call): a raising guardrail denies
    #     the tool call (fail-closed).
    #   - "log": warn to stderr and continue.
    #   - "skip" (default): silently continue.
    module BundleLoader
      class << self
        # Load all hook plugins for a bundle into the given registry.
        #
        # @param bundle_name [String]
        # @param hooks_dir [String] directory containing the bundle's .rb hook files
        # @param metadata [Hash] basename => { event:, on_error:, priority:,
        #   sha256: } (MemoryBundle::BundleHook.parse reads it)
        # @param registry [Samagotchi::Hooks::Registry]
        # @param failures [Guardrails::LoadFailures, nil] collects hooks that
        #   failed to load
        # @param settings [Hash] the bundle's section of config.yml
        #   `bundles:` (string keys); a hook class whose initialize takes an
        #   argument gets it
        # @param requires_chi [String, nil] the bundle's requirement; when
        #   this chi doesn't meet it no hook loads (each is reported, as the
        #   plugin loader does)
        # @return [Integer] number of hooks successfully registered
        def load(bundle_name:, hooks_dir:, metadata:, registry:, failures: nil, settings: {}, requires_chi: nil)
          return 0 unless metadata.is_a?(Hash)

          too_old = MemoryBundle::Manifest.requires_chi_failure(requires_chi, Samagotchi::VERSION)
          loaded = 0
          metadata.each do |raw_basename, raw_meta|
            basename = raw_basename.to_s
            next if basename.empty?

            hook = MemoryBundle::BundleHook.parse(raw_meta)
            # A hook with no declared event cannot be auto-registered.
            next if hook.events.empty?

            fail_closed = hook.events.any? { |event| hook.fail_closed?(event) }
            what = "hook #{basename} (bundle #{bundle_name})"
            file = hooks_dir && File.join(hooks_dir, basename)
            unless file && File.exist?(file)
              failures&.add(what, "the file is missing", required: true) if fail_closed
              next
            end
            if (mismatch = too_old || sha_mismatch(file, hook.sha256, required: fail_closed))
              Log.warn(:hooks, "bundle_hook_mismatch", echo: "[samagotchi:hooks] bundle '#{bundle_name}' hook '#{basename}' not loaded: #{mismatch}", bundle: bundle_name, hook: basename.to_s)
              failures&.add(what, mismatch, required: fail_closed)
              next
            end

            begin
              load_hook_file(bundle_name, basename, file, hook, registry, settings: settings)
              loaded += 1
            rescue Exception => e # rubocop:disable Lint/RescueException -- a hook's SyntaxError or exit must not stop chi
              raise if e.is_a?(SignalException) # Ctrl-C and kill signals are the user's

              Log.error(:hooks, "bundle_hook_load_failed", echo: "[samagotchi:hooks] bundle '#{bundle_name}' hook '#{basename}' failed to load: #{e.class}: #{e.message}", bundle: bundle_name, hook: basename.to_s, error: e.class.name)
              failures&.add(what, "#{e.class}: #{e.message}", required: fail_closed,
                                  location: Guardrails::LoadFailures.location(e, File.dirname(hooks_dir)))
            end
          end
          loaded
        end

        # Build one hook file and register it in +registry+ under each of
        # its events (one instance for all: its state is shared), with its
        # priority and error policy (a fail_closed before_tool_call one
        # denies when it raises). No missing-file, sha or requires_chi
        # check: #load makes them; the test kit loads a bundle's source
        # this way.
        # @param hook [MemoryBundle::BundleHook] its manifest entry
        # @param namespace [Module, nil] the module the file is evaluated
        #   in (default: the bundle's, #namespace_for)
        # @raise [Exception] what loading or building the file raised;
        #   nothing is registered then
        def load_hook_file(bundle_name, basename, file, hook, registry, settings: {}, namespace: nil)
          plugin = instantiate(bundle_name, basename, file, settings: settings, namespace: namespace)
          hook.events.each do |event_name|
            event_sym = event_name.to_sym
            fail_closed = hook.fail_closed?(event_sym)
            policy = if fail_closed then :deny
                     elsif hook.on_error == "log" then :log
                     else :skip
                     end
            label = "#{"guardrail " if fail_closed}#{basename} (bundle #{bundle_name})"
            handler = Hooks.wrap(label: label, event: event_sym, policy: policy, log: [:hooks, "bundle_hook_failed"],
                                 fields: { bundle: bundle_name }) { |event| plugin.call(event) }
            registry.register_bundle(bundle_name, event_sym, hook_name: basename, priority: hook.priority, &handler)
          end
          nil
        end

        # Why the file doesn't match the sha256 recorded at install, or nil.
        # With none recorded, only a required hook counts as a mismatch.
        def sha_mismatch(file, recorded, required:)
          return nil if MemoryBundle::Provenance.unchecked?(recorded)

          expected = MemoryBundle::Provenance.recorded_sha(recorded)
          return (required ? "no sha256 recorded for it (reinstall the bundle)" : nil) if expected.empty?

          actual = MemoryBundle::Provenance.file_sha(file)
          return nil if actual == expected

          "its sha256 #{actual[0, 12]}… differs from the installed #{expected[0, 12]}… (edited after install? reinstall the bundle)"
        end

        # Evaluate a plugin file inside the bundle's namespace module (or
        # +namespace+) and
        # return an instance that responds to #call. A class whose
        # initialize takes an argument gets the settings (one Hash, string
        # keys); one that takes none is built bare.
        def instantiate(bundle_name, basename, file, settings: {}, namespace: nil)
          ns = namespace || namespace_for(bundle_name)
          content = File.read(file)
          ns.module_eval(content, file, 1)
          klass = Hooks.class_for(basename, ns)
          instance = Hooks.build_plugin(klass, settings)
          raise ArgumentError, "plugin #{klass.name.split("::").last} does not respond to #call" unless instance.respond_to?(:call)

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
      end
    end
  end
end
