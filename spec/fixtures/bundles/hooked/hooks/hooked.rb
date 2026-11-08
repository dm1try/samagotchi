# frozen_string_literal: true

# The hooked fixture bundle's class-file hook (spec/fixtures/bundles/hooked):
# what shipped_update_spec upgrades while chi still loads bundle hooks.
class Hooked
  def call(event)
    event[:notify]&.call("hooked saw #{event[:type]}")
  end
end
