# frozen_string_literal: true

module Samagotchi
  # The words a participant is refused with, one per condition, wherever
  # it is met: chi web's routes, the Bridge, the worker, and the
  # SessionAccess errors a chi --remote client raises for the same codes.
  # No requires, so any file can use it.
  module ParticipantMessages
    # 401 token_revoked: the owner revoked the grant, or archived or deleted its session.
    TOKEN_REVOKED = "this review link was revoked by the session's owner"
    # 401 token_expired: the grant's time ran out.
    TOKEN_EXPIRED = "this review link expired: ask the session's owner for a new one"
    # 401 token_bound: a link bound to one account (chi share --identity)
    # opened by another, or not through the auth proxy (the LAN, this
    # machine). Never names either identity.
    TOKEN_BOUND = "this review link is for another account: open it through the proxy, signed in as the person " \
                  "it was sent to"
    # Either of those, where only that the link ended is known: the
    # worker's cancel_reason "revoked" (participants.json reads them
    # removed or past expires_at), as their chi send --wait reports it.
    TOKEN_ENDED = "this review link was revoked or expired"
    # 403 not_permitted: a route, a command or a shell line only the owner may use.
    NOT_PERMITTED = "a participant can't do that: only the session's owner can"
    # 429 too_many_turns: their running turn and its queue are full.
    TOO_MANY_TURNS = "this participant has too many turns waiting: wait for one to finish"
    # 429 cap_reached: their grant spent its cap.
    CAP_REACHED = "this participant's spending cap is reached: ask the session's owner to raise it"
    # Their turn failed (a wait's error, a failed turn's no_reply): never
    # the exception's words or the failure summary, which may name a path.
    TURN_FAILED = "this turn failed: the session's owner can see why"
    # A participant's Stop on a worker that can't stop only the turn named
    # (Delivery::CANCEL_TURN_ID_FEATURE): it might stop the owner's next turn.
    CANCEL_UNAVAILABLE = "this session's worker is too old to stop only your turn: ask the session's owner to restart it"
    # 429 too_many_images: their grant uploaded Grants::MAX_IMAGES distinct images.
    TOO_MANY_IMAGES = "this participant's image allowance is used up: describe what the image shows"
    # 429 too_many_image_attempts: Grants::MAX_IMAGE_ATTEMPTS uploads tried, refused ones counted.
    TOO_MANY_IMAGE_ATTEMPTS = "this participant has tried too many image uploads: describe what the image shows"
    # 422 unsupported_image: a bmp, tiff or heic, the formats chi converts
    # with an external tool (sips or magick). Their png, jpeg, gif or webp
    # still goes through the tool when it must be downscaled.
    IMAGE_TYPE = "this image type can't be sent from a participant's page: send a png, jpeg, gif or webp"
    # 422 image_too_big: no size in its header, or over the participant
    # limits (Web::ParticipantImages::MAX_PARTICIPANT_PIXELS / _SIDE).
    IMAGE_TOO_BIG = "this image is too large to send from a participant's page: send a smaller one (at most 40 megapixels)"
    # 422 bad_image: their upload isn't an image chi can store. Never
    # ImageStore's words (an image tool's output may name a host path).
    BAD_IMAGE = "this file can't be sent as an image: send a png, jpeg, gif or webp"
    # 422 no_vision: their turn has images and the session's model can't
    # take them. Never the model's name or the /model hint: those are the
    # owner's (the audit line has the full refusal).
    NO_VISION = "this session's model can't take images: send text only"
  end
end
