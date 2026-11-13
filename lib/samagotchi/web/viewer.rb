# frozen_string_literal: true

require_relative "../client_id"

module Samagotchi
  module Web
    # Who looks at chi web's main page and what they may do there: the
    # page draws a control, and makes a call, only when +can+ names its
    # capability (viewer.js; docs/internals/web-frontend.md, The viewer).
    # Not Web::Capabilities: that one says what the page renders (markdown
    # display) and whether this request's viewer can open a path in this
    # machine's editor; this one says which of the owner's controls this
    # viewer gets at all. The page reads it from <body> at boot
    # (App#index_data_attributes, #body_data) and from a show's +viewer+.
    #
    # +kind+ "owner" | "participant"; +id+ and +name+ a participant's grant's
    # (nil for the owner); +can+ the frozen list of capability names.
    Viewer = Data.define(:kind, :id, :name, :can) do
      # @param principal [Principal] the request's
      # @return [Viewer] the owner's with every capability; a participant's
      #   with PARTICIPANT_CAPABILITIES only (what their routes serve).
      def self.for(principal)
        return Viewer::OWNER if principal.owner?

        grant = principal.grant
        new(kind: "participant", id: grant.id, name: grant.name, can: Viewer::PARTICIPANT_CAPABILITIES)
      end

      def owner? = kind == "owner"

      # The client id chi web gives this viewer's turns (it replaces the
      # body's): a participant's review:<grant id> (ClientId.review), so the
      # page can tell its own turns; nil for the owner (each tab names its own).
      def client_id = owner? ? nil : ClientId.review(id)

      def can?(name) = can.include?(name.to_s)

      # The <body> data attributes the page reads at boot: the kind and the
      # space-separated +can+ list (no names or ids: those come with a show).
      def body_attributes = { "viewer-kind" => kind, "viewer-can" => can.join(" ") }

      # A participant's carries their client id too.
      def to_h = { kind: kind, id: id, name: name, can: can, **(owner? ? {} : { client_id: client_id }) }
    end

    # The capabilities the main page gates by, each named for what the
    # owner does with it (the page's controls and calls behind each one:
    # docs/internals/web-frontend.md, The viewer).
    Viewer::CAPABILITIES = %w[
      sessions models prompt_history push context working_set participants_admin rename images session_controls
      revise apply answer_cards render block_renderers stop_any_turn steer_any_turn
    ].freeze

    # A participant's capabilities: names of their own (the owner's are
    # CAPABILITIES), each one a participant route serves. +send+: their
    # composer (POST …/turn); +stop_own_turn+: the stage's Stop turn on a
    # turn they started (POST …/cancel with its turn_id); +steer_own_turn+:
    # a message sent while their own turn runs goes in at its next step
    # (a worker with Delivery::OWN_TURN_STEER_FEATURE). And of the owner's,
    # the one a participant's route serves filtered: +working_set+ (GET
    # …/working_set, the project's files only).
    Viewer::PARTICIPANT_CAPABILITIES = %w[send stop_own_turn steer_own_turn working_set].freeze

    Viewer::OWNER = Viewer.new(kind: "owner", id: nil, name: nil, can: Viewer::CAPABILITIES)
  end
end
