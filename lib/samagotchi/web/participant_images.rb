# frozen_string_literal: true

require_relative "../grants"
require_relative "../image_store"
require_relative "../participant_messages"
require_relative "../participant_uploads"
require_relative "../participants"
require_relative "../session"

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
        return Upload.refused(413, "too_large", image_too_large_detail) unless bytes

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

      def too_many_images = Upload.refused(429, "too_many_images", ParticipantMessages::TOO_MANY_IMAGES)
    end
  end
end
