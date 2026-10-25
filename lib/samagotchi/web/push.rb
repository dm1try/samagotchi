# frozen_string_literal: true

require_relative "push/crypto"
require_relative "push/store"
require_relative "push/client"
require_relative "push/attention"
require_relative "push/presence"
require_relative "push/notifier"
require_relative "../config"

module Samagotchi
  module Web
    # Web Push: chi web reaches the owner's phone (a Home Screen app that
    # turned the bell on) when a session needs the user or a turn failed.
    # It needs an https public origin (web.public_url or chi web --tunnel
    # tailscale) and web.push.enabled (on by default); without a subscribed
    # device it does nothing. See docs/configuration.md (Phone
    # notifications) and docs/internals/web-push.md.
    module Push
      # chi web won't start with push as configured: a web.push.contact
      # Apple would refuse, or a key it can't read.
      class Refused < StandardError; end

      # What chi web's push routes and its Notifier share for one run: the
      # store, the client that signs with its key, the public origin the
      # devices subscribe on, and the pages' presence (the route writes it,
      # the Notifier reads it).
      Runtime = Data.define(:store, :client, :origin, :presence) do
        def initialize(presence: Presence.new, **) = super
      end

      module_function

      # Push runs for +public_url+ (nil: none) when web.push.enabled.
      def active?(public_url) = !public_url.nil? && Config.get("web.push.enabled") != false

      # The VAPID sub: web.push.contact, else the public origin.
      # @raise [Refused] a contact that isn't a mailto: or https URL
      def contact(origin)
        given = Config.get("web.push.contact").to_s.strip
        return origin if given.empty?
        return given if Crypto.valid_sub?(given)

        raise Refused, "web.push.contact must be a mailto: address or an https URL (the push services refuse " \
                       "anything else), not #{given[0, 80]}"
      end

      # Server.launch's check, before a tunnel goes up: the contact, the
      # store's permissions and its key (made the first time).
      # @raise [Refused, Store::Insecure]
      def preflight!(public_url, store: Store.new)
        return unless active?(public_url)

        contact(public_url.origin)
        store.check_permissions!
        load_key(store)
      end

      # @raise [Refused] vapid.pem is there but isn't a key
      def load_key(store)
        store.vapid_key
      rescue OpenSSL::PKey::PKeyError => e
        raise Refused, "#{store.key_path} isn't a key chi can read (#{e.message[0, 80]}): move it aside and turn " \
                       "the bell on again on each device"
      end

      # This run's Runtime, nil when push is off.
      def runtime(public_url, state_dir: nil)
        return nil unless active?(public_url)

        store = Store.new(Store.dir(state_dir: state_dir))
        Runtime.new(store: store, client: Client.new(key: load_key(store), contact: contact(public_url.origin)),
                    origin: public_url.origin)
      end
    end
  end
end
