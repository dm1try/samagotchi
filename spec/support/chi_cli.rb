# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "bounded_capture"

# Running bin/chi in a child process. Included in every example group by
# spec_helper; a file whose calls all share arguments wraps it in its own
# run_chi and calls super.
#
#   out, err, status = run_chi("sessions", "list", env: { "XDG_STATE_HOME" => dir })
module ChiCli
  CHI = File.expand_path("../../bin/chi", __dir__)

  # A chi of its own under +dir+: config, state and HOME there, and none of
  # the model settings the suite's ENV may carry.
  def isolated_chi_env(dir, **extra)
    { "XDG_CONFIG_HOME" => File.join(dir, "config"), "XDG_STATE_HOME" => File.join(dir, "state"), "HOME" => dir,
      "SAMAGOTCHI_DEFAULT_MODEL" => nil, "SAMAGOTCHI_MODEL_PROFILE" => nil }.merge(extra)
  end

  # Run chi with empty stdin. With +timeout+ the whole process group is
  # killed past it (BoundedCapture), for a run that could hang.
  # @return [Array(String, String, Process::Status)]
  def run_chi(*, env: {}, chdir: nil, timeout: nil)
    return BoundedCapture.capture3(env, RbConfig.ruby, CHI, *, stdin_data: "", timeout: timeout, chdir: chdir) if timeout

    Open3.capture3(env, RbConfig.ruby, CHI, *, stdin_data: "", **(chdir ? { chdir: chdir } : {}))
  end
end
