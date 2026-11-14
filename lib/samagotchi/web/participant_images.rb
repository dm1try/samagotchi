# frozen_string_literal: true

require_relative "../grants"
require_relative "../image_store"
require_relative "../participant_messages"
require_relative "../participant_uploads"
require_relative "../participants"
require_relative "../send_command"
require_relative "../session"
require_relative "request_body"

module Samagotchi
  module Web
    # A participant's images, mixed into App: their uploads (POST
    # /api/sessions/:id/images) and reading their own back (GET
    # …/images/<hash>.<ext>). Ownership is ParticipantUploads' record alone,
    # written here, under @participant_images_mutex. Their turn's refs are
    # checked by ParticipantAccess#participant_images_refusal. See
    # docs/internals/participants.md (Participant images).
    module ParticipantImages
      # One upload's answer: +ref+ when accepted, else +status+, +code+ and
      # +detail+; +bytes+ the stored size (for the audit line).
      Upload = Data.define(:status, :code, :detail, :ref, :bytes) do
        def self.refused(status, code, detail) = new(status: status, code: code, detail: detail, ref: nil, bytes: nil)
        def self.accepted(ref) = new(status: 201, code: nil, detail: nil, ref: ref, bytes: ref[:bytes])
      end

      private

      # The largest image a participant may upload, by its header: pixels
      # and either side (a phone's 4032×3024 passes). Checked before any
      # tool reads their bytes.
      MAX_PARTICIPANT_PIXELS = 40_000_000
      MAX_PARTICIPANT_SIDE = 12_000

      def init_participant_images
        @participant_images_mutex = Mutex.new
        # One participant conversion (ImageStore.ingest, which may run sips
        # or magick on their bytes) at a time, whoever's.
        @participant_conversion_mutex = Mutex.new
      end

      # POST /api/sessions/:id/images from a participant. Every upload
      # counts as an attempt first (before the cap check). Refused, in
      # order: their cap (429 cap_reached), their attempts (429
      # too_many_image_attempts, refused ones counted), the size (413, as
      # the owner's), not an image (422 bad_image), a bmp/tiff/heic (422
      # unsupported_image: chi converts those with an external tool), no
      # size in its header or over MAX_PARTICIPANT_PIXELS / _SIDE (422
      # image_too_big), their quota (429 too_many_images; a file they own
      # already is accepted again, no new entry). Every answer is audited,
      # an exception too (internal_error, then raised). The reply is the ref
      # without source, mime or bytes.
      def participant_image_upload(req, id, session_dir)
        grant = principal(req).grant
        upload = begin
          participant_upload(req, session_dir, grant)
        rescue StandardError
          audit_image(id, grant, Upload.refused(500, "internal_error", nil))
          raise
        end
        audit_image(id, grant, upload)
        return error_response(upload.status, upload.code, upload.detail) unless upload.ref

        json_response(201, upload.ref.slice(:file, :name, :width, :height))
      end

      def audit_image(id, grant, upload)
        Participants.log(id, :image, state_dir: default_state_dir, participant: grant.id,
                                     status: upload.ref ? "accepted" : "refused",
                                     **{ reason: upload.code, file: upload.ref&.dig(:file), bytes: upload.bytes }.compact)
      end

      def participant_upload(req, dir, grant)
        over = @participant_images_mutex.synchronize do
          record = ParticipantUploads.read(dir)
          tried = record.attempts_of(grant.id)
          ParticipantUploads.attempt!(dir, grant.id, state: record) if tried < Grants::MAX_IMAGE_ATTEMPTS
          tried >= Grants::MAX_IMAGE_ATTEMPTS
        end
        if (cap = participant_cap_refusal(grant))
          return Upload.refused(*cap)
        end
        if over
          return Upload.refused(429, "too_many_image_attempts", ParticipantMessages::TOO_MANY_IMAGE_ATTEMPTS)
        end

        bytes = image_upload_bytes(req)
        return Upload.refused(413, "too_large", bytes.message) if bytes.is_a?(RequestBody::BodyTooLarge)

        participant_store(dir, grant, bytes, upload_name(req))
      end

      def participant_store(dir, grant, bytes, name)
        info = ImageHeader.read(bytes)
        return Upload.refused(422, "bad_image", ParticipantMessages::BAD_IMAGE) unless info
        if ImageHeader::CONVERTIBLE.include?(info.format)
          return Upload.refused(422, "unsupported_image", ParticipantMessages::IMAGE_TYPE)
        end
        return Upload.refused(422, "image_too_big", ParticipantMessages::IMAGE_TOO_BIG) unless participant_size_ok?(info)

        # At quota: only a file they own already, named as its bytes would
        # be stored unchanged (a downscaled or re-encoded one is refused).
        raw = ImageStore.file_name_for(bytes, info.format)
        again = @participant_images_mutex.synchronize do
          record = ParticipantUploads.read(dir)
          next nil if record.count(grant.id) < Grants::MAX_IMAGES

          record.owned?(raw, grant.id)
        end
        return Upload.accepted(ImageStore.ref_for(dir, file: raw, name: name)) if again
        return too_many_images if again == false

        participant_ingest(dir, grant, bytes, name)
      rescue ImageStore::Error
        Upload.refused(422, "bad_image", ParticipantMessages::BAD_IMAGE)
      end

      # Whether +info+'s header gives a size within the participant limits.
      def participant_size_ok?(info)
        return false unless info.width.is_a?(Integer) && info.height.is_a?(Integer) && info.width.positive? && info.height.positive?

        [info.width, info.height].max <= MAX_PARTICIPANT_SIDE && info.width * info.height <= MAX_PARTICIPANT_PIXELS
      end

      # Stores their image, then records it: the quota checked again under
      # the mutex (a race past it is refused here; the stored file may stay
      # in images/, unreachable to them without a record).
      def participant_ingest(dir, grant, bytes, name)
        ref = @participant_conversion_mutex.synchronize { ImageStore.ingest(dir, bytes: bytes, name: name, source: "user") }
        added = @participant_images_mutex.synchronize do
          record = ParticipantUploads.read(dir)
          next true if record.owned?(ref[:file], grant.id)
          next false if record.count(grant.id) >= Grants::MAX_IMAGES

          ParticipantUploads.add(dir, file: ref[:file], grant_id: grant.id, state: record)
        end
        added ? Upload.accepted(ref) : too_many_images
      end

      # A participant's turn's images: [nil, refs] to deliver (refs [] for
      # none), or [[status, code, detail(, audit detail)], nil]. In this
      # order, so nothing tells them which files exist: the shape (400
      # bad_images), then ownership (403 not_permitted for any ref they
      # didn't upload, there or not), only then the files (ImageStore.
      # check_refs), then the model (422 no_vision in their words; the
      # model's name and the /model hint only in the audit line).
      def participant_images_refusal(grant, id, raw)
        return [nil, []] if raw.nil? || raw == []
        return [[400, "bad_images", ParticipantMessages::IMAGES_SHAPE], nil] unless participant_refs_shape?(raw)

        dir = Session.session_dir(id, state_dir: default_state_dir)
        record = @participant_images_mutex.synchronize { ParticipantUploads.read(dir) }
        owned = raw.all? { |ref| record.owned?(ref["file"].to_s, grant.id) }
        return [[403, "not_permitted", ParticipantMessages::NOT_PERMITTED], nil] unless owned

        images = ImageStore.check_refs(dir, raw)
        return [[400, "bad_images", ParticipantMessages::IMAGE_GONE, images], nil] if images.is_a?(String)

        refusal = participant_vision_refusal(id)
        refusal ? [[422, "no_vision", ParticipantMessages::NO_VISION, refusal], nil] : [nil, images]
      end

      def participant_refs_shape?(raw)
        raw.is_a?(Array) && raw.size <= ImageStore::MAX_TURN_REFS &&
          raw.all? { |ref| ref.is_a?(Hash) && ref["file"].is_a?(String) && !ref.key?("path") }
      end

      # chi send's refusal for this session's model, nil when it takes
      # images or nobody knows (the Engine stays the backstop). The model's
      # name can lag a live /model.
      def participant_vision_refusal(id)
        session = @session_class.load(id, state_dir: default_state_dir)
        SendCommand.vision_refusal_for(session.model_name, typed: session.model_typed)
      end

      # Whether the request's participant uploaded <session_dir>/images/+name+
      # (a bare "<hash>.<ext>"): the record alone (they had the bytes).
      def participant_owns_image?(req, session_dir, name)
        ParticipantUploads.owned?(session_dir, "#{ImageStore::DIR}/#{name}", principal(req).grant.id)
      end

      def too_many_images = Upload.refused(429, "too_many_images", ParticipantMessages::TOO_MANY_IMAGES)
    end
  end
end
