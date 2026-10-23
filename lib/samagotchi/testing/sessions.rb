# frozen_string_literal: true

require_relative "../plugin/context"

module Samagotchi
  module Testing
    # One ctx.sessions call: the method's name and its arguments.
    SessionCall = Data.define(:name, :args, :options)

    # ctx.sessions recorded (Plugin::Sessions' methods, same signatures:
    # the contract spec checks): each call lands in #calls and returns a
    # scripted answer (#on), or by default: fork a new id ("fork-1"…),
    # review a new id ("review-1"…), send
    # and stop the id they got, children [], read raises
    # Plugin::Sessions::Error (no such session).
    #
    #   bundle.sessions.on(:children) { |all:| [{ id: "c1", status: "running" }] }
    #   bundle.sessions.on(:send) { |id, text, delivery:| raise Samagotchi::Plugin::Sessions::Error, "busy" }
    class Sessions
      METHODS = %i[fork review send read children stop].freeze

      def initialize
        @calls = []
        @scripts = {}
        @forks = 0
        @reviews = 0
        @mutex = Mutex.new
      end

      # @return [Array<SessionCall>]
      def calls = @mutex.synchronize { @calls.dup }

      # The calls of one method.
      def calls_to(method) = calls.select { |call| call.name == method }

      # Answer +method+'s calls with the block (it gets the call's
      # arguments; a raise is the call's).
      def on(method, &block)
        raise ArgumentError, "ctx.sessions has no #{method} (#{METHODS.join(", ")})" unless METHODS.include?(method)
        raise ArgumentError, "on(#{method}) needs a block" unless block

        @mutex.synchronize { @scripts[method] = block }
        self
      end

      def fork(messages:, title: nil, prompt: nil)
        answer(:fork, [], { messages: messages, title: title, prompt: prompt }) do
          "fork-#{@mutex.synchronize { @forks += 1 }}"
        end
      end

      def review(subjects: [], seed: nil, recap_wait: 0)
        answer(:review, [], { subjects: subjects, seed: seed, recap_wait: recap_wait }) do
          "review-#{@mutex.synchronize { @reviews += 1 }}"
        end
      end

      def send(id, text, delivery: nil)
        answer(:send, [id, text], { delivery: delivery }) { id }
      end

      def read(id)
        answer(:read, [id], {}) { raise Plugin::Sessions::Error, "no session #{id}" }
      end

      def children(all: false)
        answer(:children, [], { all: all }) { [] }
      end

      def stop(id)
        answer(:stop, [id], {}) { id }
      end

      private

      def answer(method, args, options)
        script = @mutex.synchronize do
          @calls << SessionCall.new(name: method, args: args.freeze, options: options.freeze)
          @scripts[method]
        end
        script ? script.call(*args, **options) : yield
      end
    end
  end
end
