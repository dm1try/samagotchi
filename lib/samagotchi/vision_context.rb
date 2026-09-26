# frozen_string_literal: true

require "securerandom"
require_relative "image_store"

module Samagotchi
  # What a turn's loops need to send images, set on the kernel by the
  # Engine for one turn:
  #   capability  VisionSupport::Answer (nil: unknown, send), or a callable
  #               that answers it on first need (a probe only when a turn
  #               has images)
  #   session_dir where the session's images/ are (refs resolve against it)
  #   limits      ImageStore::Limits
  #   resizer     ImageResizer for images a tool returns (nil: detect)
  class VisionContext
    attr_reader :session_dir, :limits, :resizer

    def initialize(capability: nil, session_dir: nil, limits: ImageStore::Limits.from_config, resizer: nil)
      @capability = capability
      @session_dir = session_dir
      @limits = limits
      @resizer = resizer
      @mutex = Mutex.new
    end

    def capability
      @mutex.synchronize do
        @capability = @capability.call if @capability.respond_to?(:call)
        @capability
      end
    end

    def with(**changes)
      self.class.new(capability: @capability, session_dir: session_dir, limits: limits, resizer: resizer, **changes)
    end

    # False only when the model is known not to see images.
    def sendable? = capability.nil? || capability.value != false

    # Why images aren't sent, for a line or a refusal.
    def refusal_reason = capability&.reason || ImagePlan::CANT_SEE

    # The ref's base64, or nil when it isn't a valid ref of this session.
    def base64(ref)
      return nil unless session_dir && ImageStore.valid_ref?(session_dir, ref)

      ImageStore.base64(session_dir, ref)
    rescue StandardError
      nil
    end

    def data_uri(ref)
      data = base64(ref)
      data && "data:#{ref[:mime] || ref["mime"]};base64,#{data}"
    end

    # Stores an image a tool read or returned (source "tool", from a +path+
    # or raw +bytes+) and returns its ref.
    def ingest(path = nil, name: nil, bytes: nil)
      raise ImageStore::Error, "no session to keep the image in" unless session_dir

      ImageStore.ingest(session_dir, path: path, bytes: bytes, name: name, source: "tool", limits: limits,
                                     resizer: resizer || ImageResizer.detect)
    end
  end

  # Which images of a conversation one request sends. Every image that is
  # not sent becomes a placeholder line: all of them when the model can't
  # see images, the older ones past limits.max_per_request (the newest go),
  # and any whose file is gone.
  class ImagePlan
    Item = Data.define(:ref, :data, :placeholder) do
      def sent? = !data.nil?
    end

    ROLES = %w[user tool_response].freeze
    CANT_SEE = "this model can't see images"
    # Stands for the server's media marker in a native prompt until
    # Client#complete swaps in the live one (random, so no typed text has it).
    NATIVE_PLACEHOLDER = "<__chi_image_#{SecureRandom.hex(8)}__>".freeze

    # @param conversation [Array<Hash>] engine-format messages
    # @param vision [VisionContext, nil]
    # @param data [Symbol] :base64 (native) or :data_uri (chat)
    def initialize(conversation, vision, data: :data_uri)
      @vision = vision
      @data = data
      occurrences = []
      conversation.each_with_index do |entry, index|
        next unless ROLES.include?(entry[:role].to_s)

        Array(entry[:images]).each_index { |position| occurrences << [index, position] }
      end
      @limit = vision&.limits&.max_per_request || ImageStore::Limits.from_config.max_per_request
      @sent = occurrences.last(@limit)
    end

    # The Items for conversation[+index+] (none when it has no images).
    def items(entry, index)
      return [] unless ROLES.include?(entry[:role].to_s)

      Array(entry[:images]).each_with_index.map do |raw, position|
        ref = ImageStore.symbolize(raw)
        reason = skip_reason(index, position)
        data = reason ? nil : fetch(ref)
        reason ||= "the image file is missing" unless data
        Item.new(ref: ref, data: data, placeholder: reason && ImageRef.placeholder(ref, reason))
      end
    end

    # Estimated tokens of the images a request sends (ImageRef.estimated_tokens).
    def self.estimated_tokens(conversation)
      conversation.sum do |entry|
        ROLES.include?(entry[:role].to_s) ? Array(entry[:images]).sum { |ref| ImageRef.estimated_tokens(ImageStore.symbolize(ref)) } : 0
      end
    end

    private

    def skip_reason(index, position)
      return "no session images here" if @vision.nil?
      return CANT_SEE unless @vision.sendable?
      return "only the newest #{@limit} images are sent" unless @sent.include?([index, position])

      nil
    end

    def fetch(ref)
      @data == :base64 ? @vision.base64(ref) : @vision.data_uri(ref)
    end
  end
end
