# frozen_string_literal: true

require_relative "effective_model"
require_relative "model_overlay"
require_relative "model_profile"

module Samagotchi
  # An Engine's model choice (ModelChoice: the model as given and as typed)
  # and the prompt profile resolved for it, under one mutex; the counterpart
  # of ToolkitBinding. The memory overlay keys follow the choice
  # (#sync_model_key!).
  #
  # The choice changes in one assignment under the mutex (#switch!), so a
  # reader on another thread sees the old pair or the new one. A resolution
  # is kept and applied only for the choice it was resolved for, by
  # identity (#store_profile: a /stats on a Bridge thread probing while
  # /model runs keeps nothing). Nothing else takes the mutex.
  #
  # What it needs from the Engine comes through lookups, called at use; the
  # Engine forwards each method here.
  class ModelBinding
    # @param choice         [ModelChoice] the starting model
    # @param given_profile  [ModelProfile, nil] a caller's profile (until a switch)
    # @param registry       [HostRegistry]
    # @param kernel         [#call] → KernelLoop
    # @param prompt_builder [#call] → SystemPrompt, nil while the Engine is built
    # @param bare_name      [#call] (ref) → the model id sent for +ref+
    def initialize(choice:, given_profile:, registry:, kernel:, prompt_builder:, bare_name:)
      @choice = choice
      @given_profile = given_profile
      @registry = registry
      @kernel = kernel
      @prompt_builder = prompt_builder
      @bare_name = bare_name
      # Guards the model choice and the profile cached for it (#store_profile).
      @mutex = Mutex.new
      # [choice, resolution]: the resolution kept, with the choice it is for.
      @resolution = nil
      @model_key = nil
      @fallback_model_key = nil
    end

    # @return [ModelChoice] the model turns run on now
    attr_reader :choice

    # @return [ModelProfile, nil] the profile given to the Engine, nil after a switch
    attr_reader :given_profile

    # The effective model's key (ModelOverlay.key_for its bare name), and
    # the typed name's when that differs (#sync_model_key!).
    # @return [String, nil]
    attr_reader :model_key, :fallback_model_key

    # Moves to +choice+ (Engine#switch_model!): the given profile and the
    # kept resolution go with the old one.
    def switch!(choice)
      @mutex.synchronize do
        # One assignment: a reader on another thread sees the old pair or the new one.
        @choice = choice
        # A profile given to .new was for the starting model.
        @given_profile = nil
        @resolution = nil
      end
    end

    # Which profile the effective model gets and where that came from
    # (ModelProfile.resolve: --profile/env, models:, hosts.<name>.profile,
    # the server's chat template, the name, qwen36). Resolved on first need
    # and kept, so the system prompt and the server's KV prefix stay stable;
    # #switch! starts over, and a failed server probe is retried before
    # the next turn (#refresh_profile!). The kernel follows each resolution.
    # Kept with the model choice it was resolved for: one that finishes
    # after a switch is neither kept nor applied (#store_profile).
    # @return [ModelProfile::Resolution]
    def profile_resolution
      choice = @choice
      cached = @resolution
      return cached.last if cached&.first.equal?(choice)

      store_profile(choice, resolve_profile(choice))
    end

    # +choice+'s profile (ModelProfile.resolve; may probe /props), or the
    # one given to .new.
    def resolve_profile(choice)
      given = @given_profile
      return ModelProfile::Resolution.new(profile: given, source: :given, detail: nil, retry: false) if given

      EffectiveModel.of(@registry, choice).profile_resolution
    end

    # Keeps +resolution+ as +choice+'s and applies it, unless the model
    # switched while it was resolved (a /stats on a Bridge thread probing
    # as a /model ran): then it is only returned, and the new model's is
    # resolved on its first need.
    # @return [ModelProfile::Resolution]
    def store_profile(choice, resolution)
      @mutex.synchronize do
        return resolution unless @choice.equal?(choice)

        apply_profile(resolution)
        @resolution = [choice, resolution]
      end
      resolution
    end

    # Everything that holds a profile follows the resolution: the kernel's
    # prompt format and parser, and the system prompts built for the old one.
    def apply_profile(resolution)
      kept = @resolution&.last
      @prompt_builder.call&.reset! if kept && kept.profile.name != resolution.profile.name
      @kernel.call.use_profile!(resolution)
      resolution
    end

    # Before a turn: resolve now if nothing has yet, or again if the last
    # server probe failed (unreachable, or 503 while loading a model). A
    # profile that changes here drops the cached system prompts.
    def refresh_profile!
      choice, kept = @resolution
      return profile_resolution unless choice.equal?(@choice) && kept.retry?

      store_profile(choice, resolve_profile(choice))
    end

    # The memory overlay key follows the model sent (ModelOverlay.key_for
    # its id). A model typed as an alias used to key overlays by the alias
    # (before aliases were applied there): that key is read when the
    # target's overlay is missing (KernelLoop#sync_model_key!).
    def sync_model_key!
      choice = @choice
      @model_key = ModelOverlay.key_for(@bare_name.call(choice.name))
      typed_key = ModelOverlay.key_for(@registry.parse_qualified_model(choice.typed).last)
      @fallback_model_key = typed_key == @model_key ? nil : typed_key
      @kernel.call.sync_model_key!(@model_key, fallback: @fallback_model_key)
    end
  end
end
