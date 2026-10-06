# frozen_string_literal: true

require_relative "guardrails/verdict"
require_relative "guardrails/context"
require_relative "guardrails/outside"
require_relative "guardrails/shell_lex"
require_relative "guardrails/shell_git_dirs"
require_relative "guardrails/read_only_shell"
require_relative "guardrails/targets"
require_relative "guardrails/model_size"
require_relative "guardrails/approval"
require_relative "guardrails/approvals"
require_relative "guardrails/protected_paths"
require_relative "guardrails/scratch_writes"
require_relative "guardrails/child_boundary"
require_relative "guardrails/load_failures"
require_relative "guardrails/rules"
require_relative "guardrails/gate"

module Samagotchi
  # Tool guardrails: the verdict every model tool call gets before it is
  # dispatched. ToolRunner asks the Gate; hooks and rules vote.
  module Guardrails
  end
end
