# frozen_string_literal: true

require_relative "errors"

module Samagotchi
  module SystemOne
    # The backend the specs use: answers from a block, from a fixed hash, or
    # an error every time. It never reaches the network.
    #
    #   FakeBackend.new { |state, questions| {questions.first.id => answer} }
    #   FakeBackend.new("git-push" => Answer.from_wire("git-push", {"type" => "noul", "noul" => 0.97}))
    #   FakeBackend.new(failing: true)
    class FakeBackend
      attr_reader :calls

      # @param answers [Hash{String => Answer}, nil] the same answers for
      #   every call
      # @param failing [Boolean] true: every #ask raises
      # @param error [String] what a failing backend says
      # @param judgments [#call] (state, questions) => {id => Answer}
      def initialize(answers = nil, failing: false, error: "fake System One backend is unavailable", &judgments)
        @answers = answers
        @judgments = judgments
        @failing = failing
        @error = error
        @calls = 0
      end

      def ask(state:, questions:, cancel_controller: nil)
        @calls += 1
        raise BackendError, @error if @failing

        judged = @judgments&.call(state, questions)
        return judged unless judged.nil?

        ids = Array(questions).map { |question| question.respond_to?(:id) ? question.id : question.to_s }
        (@answers || {}).select { |id, _answer| ids.include?(id) }
      end

      def failing? = @failing

      def inspect = "#<#{self.class.name} calls=#{@calls}#{" failing" if @failing}>"
    end
  end
end
