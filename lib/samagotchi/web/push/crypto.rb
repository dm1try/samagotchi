# frozen_string_literal: true

require "json"
require "openssl"
require "uri"

module Samagotchi
  module Web
    module Push
      # Web Push's two pieces of crypto, on OpenSSL alone (no gem): the
      # message body a push service carries to the device (RFC 8291's
      # aes128gcm, RFC 8188: one record, no padding), and the VAPID
      # Authorization header that says the push comes from chi web's key
      # (RFC 8292: an ES256 JWT for the endpoint's origin). The RFC 8291
      # Appendix A vector pins #encrypt byte for byte
      # (spec/web/push/crypto_spec.rb). See docs/internals/web-push.md.
      module Crypto
        module_function

        GROUP = "prime256v1"
        # RFC 8188's record size: one record holds a push message (< 4 KB).
        RECORD_SIZE = 4096
        # A VAPID token lives this long (RFC 8292 allows up to 24 h).
        JWT_TTL = 12 * 3600

        def b64u(bytes) = [bytes].pack("m0").tr("+/", "-_").delete("=")

        # base64url with or without its padding; ArgumentError when it
        # isn't base64url.
        def unb64u(text)
          text = text.to_s
          raise ArgumentError, "not base64url" unless text.match?(/\A[A-Za-z0-9_-]*={0,2}\z/)

          text = text.delete_suffix("=").delete_suffix("=")
          raise ArgumentError, "not base64url" if text.length % 4 == 1

          (text.tr("-_", "+/") + ("=" * ((4 - (text.length % 4)) % 4))).unpack1("m0")
        end

        # A new P-256 key (chi web's VAPID key; a message's sender key).
        def generate_key = OpenSSL::PKey::EC.generate(GROUP)

        # The 65-byte uncompressed point of +key+'s public half.
        def raw_public(key) = key.public_key.to_octet_string(:uncompressed)

        # What the page hands pushManager.subscribe as applicationServerKey.
        def public_key_b64(key) = b64u(raw_public(key))

        # A P-256 public key from its 65-byte uncompressed point (OpenSSL 3
        # keys are immutable: built through an SPKI DER).
        def ec_public(raw)
          spki = OpenSSL::ASN1::Sequence([
            OpenSSL::ASN1::Sequence([OpenSSL::ASN1::ObjectId("id-ecPublicKey"),
                                     OpenSSL::ASN1::ObjectId(GROUP)]),
            OpenSSL::ASN1::BitString(raw)
          ])
          OpenSSL::PKey::EC.new(spki.to_der)
        end

        # A P-256 key pair from its 32-byte private scalar and its public
        # point (RFC 8291's fixed sender key, a spec's receiver).
        def ec_private(priv, pub)
          der = OpenSSL::ASN1::Sequence([
            OpenSSL::ASN1::Integer(1),
            OpenSSL::ASN1::OctetString(priv),
            OpenSSL::ASN1::ObjectId(GROUP, 0, :EXPLICIT),
            OpenSSL::ASN1::BitString(pub, 1, :EXPLICIT)
          ])
          OpenSSL::PKey::EC.new(der.to_der)
        end

        def hkdf(salt, ikm, info, length) = OpenSSL::KDF.hkdf(ikm, salt: salt, info: info, length: length, hash: "SHA256")

        # RFC 8291 §3.4: +plaintext+ for the device whose subscription keys
        # are +p256dh+ (its 65-byte public point) and +auth+ (16 bytes), as
        # one aes128gcm record (RFC 8188 §2: salt, rs, idlen, keyid, then the
        # record with its 0x02 delimiter and no padding). +salt+ and
        # +sender_key+ are fresh per message; the RFC vector fixes them.
        # @return [String] the request body (binary)
        def encrypt(plaintext, p256dh:, auth:, salt: OpenSSL::Random.random_bytes(16), sender_key: generate_key)
          sender_public = raw_public(sender_key)
          shared = sender_key.derive(ec_public(p256dh))
          ikm = hkdf(auth, shared, "WebPush: info\0".b + p256dh.b + sender_public, 32)
          cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm\0".b, 16)
          nonce = hkdf(salt, ikm, "Content-Encoding: nonce\0".b, 12)
          cipher = OpenSSL::Cipher.new("aes-128-gcm").encrypt
          cipher.key = cek
          cipher.iv = nonce
          record = cipher.update("#{plaintext.b}\x02".b) + cipher.final + cipher.auth_tag
          salt.b + [RECORD_SIZE].pack("N") + [sender_public.bytesize].pack("C") + sender_public + record
        end

        # RFC 8292: the Authorization header for a push to +endpoint+, signed
        # with +key+ (chi web's VAPID key): aud = the endpoint's origin, exp
        # = +now+ + JWT_TTL, sub = +sub+ (a contact URL: valid_sub?).
        # @param now [Time]
        def vapid_authorization(endpoint, key:, sub:, now: Time.now)
          claims = { aud: origin_of(endpoint), exp: now.to_i + JWT_TTL, sub: sub }
          input = "#{b64u(JSON.generate({ typ: "JWT", alg: "ES256" }))}.#{b64u(JSON.generate(claims))}"
          # ES256 wants r‖s, 32 bytes each; OpenSSL signs DER.
          r, s = OpenSSL::ASN1.decode(key.sign("SHA256", input)).value.map { |int| int.value.to_s(2).rjust(32, "\0") }
          "vapid t=#{input}.#{b64u(r + s)}, k=#{public_key_b64(key)}"
        end

        # scheme://host[:port] of a URL, the port only when it isn't the
        # scheme's default.
        def origin_of(url)
          uri = URI(url)
          "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
        end

        # A VAPID sub Apple takes: a mailto: with an @, or an https URL with
        # a host. A bare "chi@localhost" gets 403 BadJwtToken (the spike).
        def valid_sub?(sub)
          text = sub.to_s
          return text.match?(/\Amailto:[^@\s]+@[^@\s]+\z/) if text.start_with?("mailto:")

          uri = URI.parse(text)
          uri.scheme == "https" && !uri.host.to_s.empty?
        rescue URI::InvalidURIError
          false
        end
      end
    end
  end
end
