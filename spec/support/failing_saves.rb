# frozen_string_literal: true

# Session#save raising Errno::ENOSPC (a full disk) while saves_fail is
# set, and the worker's "save_failed" log records, by the save's at:
# (Worker#save_or_log), in failed_saves.
RSpec.shared_context "failing session saves" do
  let(:failed_saves) { [] }

  before do
    @saves_fail = false
    failed = failed_saves
    allow(Samagotchi::Log).to receive(:exception).and_wrap_original do |original, *args, **kwargs|
      failed << kwargs[:at] if args[1] == "save_failed"
      original.call(*args, **kwargs)
    end
    allow_any_instance_of(Samagotchi::Session).to receive(:save).and_wrap_original do |original, **kwargs|
      raise Errno::ENOSPC if @saves_fail

      original.call(**kwargs)
    end
  end

  def saves_fail!(failing = true)
    @saves_fail = failing
  end
end
