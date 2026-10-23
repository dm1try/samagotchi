# frozen_string_literal: true

# Distinct, ordered times for the lib's clock seams (Session#save(now:),
# Session.new_session(now:), SessionInbox.write_input/write_note/
# write_output(now:)), in place of a sleep that separates two millisecond
# timestamps. Included in every example group by spec_helper; each example
# starts its own run.
module SpecStamps
  # A second before the example's first call, then one millisecond later
  # on every call: always in the past (a save the lib stamps with the real
  # clock afterwards sorts newest) and exact (a Rational step, so
  # iso8601(3) never truncates two stamps into one).
  def next_stamp
    @spec_stamp = @spec_stamp ? @spec_stamp + Rational(1, 1000) : Time.now - 1
  end
end
