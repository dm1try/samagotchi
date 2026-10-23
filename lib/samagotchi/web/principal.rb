# frozen_string_literal: true

module Samagotchi
  module Web
    # Who a chi web request is (App#principal_for). Today there is one
    # kind: the owner, a peer on this machine or a request with the
    # Web::Token access token. The routes' permission column
    # (App::ROUTES, :owner or :participant) is checked against it, and a
    # turn's author comes from it, never from the request body. See
    # docs/internals/remote-sessions.md (Trust model).
    #
    # +kind+ :owner; +grant+ what a non-owner principal was admitted by
    # (nil for the owner).
    Principal = Data.define(:kind, :grant) do
      def owner? = kind == :owner

      # Whether this principal may use a route with +permission+ (a ROUTES
      # row's): the owner every route, anyone else only a :participant one.
      def permits?(permission) = owner? || permission == :participant

      # The author a turn this principal sends carries: nil for the owner,
      # so an owner's turn, its input file and its session stay as they
      # were; any other principal's names it through its grant.
      def author = owner? ? nil : grant.author
    end

    Principal::OWNER = Principal.new(kind: :owner, grant: nil)
  end
end
