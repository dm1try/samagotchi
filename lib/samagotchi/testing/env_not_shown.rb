# frozen_string_literal: true

require "pp"

# A failing matcher or assertion that meets the process ENV prints this
# instead of its contents, which hold real API keys: RSpec and Minitest format
# with #inspect and diff with pp. Loaded by the bundle kit and by chi's own
# spec suite; it needs nothing else of chi's. A stub_const("ENV", ENV.to_h...)
# is a plain Hash and isn't covered.
module Samagotchi
  module Testing
    ENV_NOT_SHOWN = "#<the process ENV, contents not shown>"
  end
end

def ENV.inspect = Samagotchi::Testing::ENV_NOT_SHOWN
def ENV.pretty_print(printer) = printer.text(Samagotchi::Testing::ENV_NOT_SHOWN)
