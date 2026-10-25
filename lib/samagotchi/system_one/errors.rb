# frozen_string_literal: true

module Samagotchi
  module SystemOne
    # A judgment that did not happen: the backend could not reach the host,
    # the host refused the request, or its answer was not usable. Client#ask
    # turns any of these into nil (no judgment), so the caller asks the user.
    class BackendError < StandardError; end

    # The named host is not a System One host: it isn't in hosts:, its api
    # is not openai, or it names no model.
    class UnsupportedHost < BackendError; end
  end
end
