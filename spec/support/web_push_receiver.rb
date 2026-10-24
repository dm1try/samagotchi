# frozen_string_literal: true

require "openssl"
require "samagotchi/web/push/crypto"

# A device's side of Web Push, for the specs: its subscription key pair and
# auth secret, and the decryption of an aes128gcm body (RFC 8291 §3.4 run
# backwards), so a spec reads what chi web sent instead of trusting it.
class WebPushReceiver
  Crypto = Samagotchi::Web::Push::Crypto

  attr_reader :key, :auth

  def initialize(key: Crypto.generate_key, auth: OpenSSL::Random.random_bytes(16))
    @key = key
    @auth = auth
  end

  def p256dh = Crypto.raw_public(@key)

  # What a browser's pushManager.subscribe hands the page, as JSON.
  def subscription(endpoint)
    { "endpoint" => endpoint, "keys" => { "p256dh" => Crypto.b64u(p256dh), "auth" => Crypto.b64u(@auth) } }
  end

  # @return [String] the plaintext (one record, delimiter 0x02 stripped)
  def decrypt(body)
    body = body.b
    salt = body[0, 16]
    rs = body[16, 4].unpack1("N")
    idlen = body[20].ord
    sender_public = body[21, idlen]
    record = body[(21 + idlen)..]
    raise "more than one record" if record.bytesize > rs

    shared = @key.derive(Crypto.ec_public(sender_public))
    ikm = Crypto.hkdf(@auth, shared, "WebPush: info\0".b + p256dh + sender_public, 32)
    cek = Crypto.hkdf(salt, ikm, "Content-Encoding: aes128gcm\0".b, 16)
    nonce = Crypto.hkdf(salt, ikm, "Content-Encoding: nonce\0".b, 12)
    cipher = OpenSSL::Cipher.new("aes-128-gcm").decrypt
    cipher.key = cek
    cipher.iv = nonce
    cipher.auth_tag = record[-16..]
    plain = cipher.update(record[0...-16]) + cipher.final
    raise "no last-record delimiter" unless plain.end_with?("\x02".b)

    plain.delete_suffix("\x02".b)
  end

  # The JWT's claims when +header+ (a vapid Authorization) verifies with
  # its own k=, else nil.
  def self.vapid_claims(header)
    jwt = header[/\Avapid t=([^,]+), k=/, 1] or return nil
    public_key = Crypto.ec_public(Crypto.unb64u(header[/k=(\S+)\z/, 1]))
    input, _, sig = jwt.rpartition(".")
    raw = Crypto.unb64u(sig)
    der = OpenSSL::ASN1::Sequence([OpenSSL::ASN1::Integer(OpenSSL::BN.new(raw[0, 32], 2)),
                                   OpenSSL::ASN1::Integer(OpenSSL::BN.new(raw[32, 32], 2))]).to_der
    return nil unless public_key.verify("SHA256", der, input)

    JSON.parse(Crypto.unb64u(input.split(".")[1]))
  end
end
