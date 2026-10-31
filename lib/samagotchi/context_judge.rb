# frozen_string_literal: true

require_relative "config"
require_relative "context_candidates_log"
require_relative "log"
require_relative "system_one/question"

module Samagotchi
  # System 1's judgment of a session's candidate context
  # (docs/context.md, "The judge"): is this session's work about the
  # candidate? One ask per candidate, its state neutral and small: the
  # candidate's title (and describe), the owner's own prompts (the first
  # substantive one and the latest, each bounded) and, for a delegate
  # child, what its parent session has attached. Never the branch or the
  # checkout (bare place facts), never the source's why, never "found for
  # this checkout". The instructions are constant (one for a session, one
  # for a delegate child): the candidate is in the state, so the server's
  # prefix cache holds and nothing a plugin wrote is read as instructions.
  #
  # The same ask has a second question, "Has the user stated a task yet?":
  # under TASK_MIN the candidate stays unjudged and is asked again at the
  # next owner prompt. After a judged ask, one re-ask once
  # context.candidates.reask_after_turns more owner prompts came, then
  # done (#due?). What it asked and answered is a `judged` line in
  # ContextCandidatesLog; in this slice nothing is attached (on mode is
  # audit until the attaching comes).
  module ContextJudge
    MODES = %w[off audit on].freeze
    ABOUT_ID = "about"
    TASK_ID = "task"
    # The bound on each prompt in the state.
    PROMPT_MAX = 1500
    # Below this the user hasn't stated a task yet: the ask is deferred.
    TASK_MIN = 0.5
    ABOUT = "A user works with a coding agent session. The state names a candidate source of context and the " \
            "user's messages in the session so far (the first one with a task, and the latest). " \
            "Is this session's work about the candidate? Work on something else is not."
    CHILD = " This session was started by another agent session: the conversation's first message is that " \
            "session's request, and started_from lists what that session has attached (the work it is doing)."
    TASK = "A user works with a coding agent session; the state holds the user's messages so far. " \
           "Has the user stated a task yet? A greeting or small talk alone is not one."

    # One ask's snapshot, taken on the turn's (or the plugin's) thread.
    # +conversation+ is the owner's prompts as the state carries them,
    # +parent_attached+ nil unless the session is a delegate child,
    # +owner_prompts+ how many owner prompts the session had (the re-ask
    # counts them), +phase+ "turn" (a turn's start or end) or "late" (a
    # proposal after the prompts).
    Job = Data.define(:session_id, :name, :title, :describe, :conversation, :parent_attached, :owner_prompts, :phase)
    # The thresholds a judged line's would is read with, and the mode.
    Settings = Data.define(:mode, :threshold, :offer_threshold, :reask_after_turns) do
      def self.from_config
        new(mode: ContextJudge.mode, threshold: Config.get("context.candidates.threshold").to_f,
            offer_threshold: Config.get("context.candidates.offer_threshold").to_f,
            reask_after_turns: [Config.get("context.candidates.reask_after_turns").to_i, 1].max)
      end
    end

    module_function

    # context.candidates.mode: off (the default: no conversation text goes
    # to a System 1 host), audit or on. An unknown value reads as off.
    def mode
      value = Config.get("context.candidates.mode").to_s.strip.downcase
      MODES.include?(value) ? value : "off"
    end

    # The bounded conversation the state carries: the first substantive
    # owner prompt and the latest (one when they are the same). +skip+
    # owner prompts at the start are not substantive (an earlier ask said
    # no task was stated in them); a delegate child skips none (its first
    # is the parent's request).
    # @param texts [Array<String>] the owner's prompts, oldest first
    # @return [Array<String>]
    def conversation(texts, skip: 0)
      texts = Array(texts).map(&:to_s).reject { |text| text.strip.empty? }
      return [] if texts.empty?

      first = skip < texts.size ? skip : 0
      picked = first == texts.size - 1 ? [texts.last] : [texts[first], texts.last]
      picked.map { |text| bound(text) }
    end

    def bound(text)
      text = text.strip
      text.length > PROMPT_MAX ? "#{text[0, PROMPT_MAX - 1]}…" : text
    end

    # The ask's state.
    # @return [Hash{String => Object}]
    def state(job)
      candidate = job.describe.to_s.strip.empty? ? job.title : "#{job.title} — #{job.describe}"
      state = { "candidate" => candidate, "conversation" => job.conversation }
      state["started_from"] = { "parent_attached" => job.parent_attached } if job.parent_attached
      state
    end

    # The two questions, constant for a session (+child+: a delegate child).
    def questions(child:)
      { ABOUT_ID => SystemOne::Question.new(id: ABOUT_ID, type: "noul", instructions: child ? ABOUT + CHILD : ABOUT),
        TASK_ID => SystemOne::Question.new(id: TASK_ID, type: "noul", instructions: TASK) }
    end

    # How many owner prompts at the start no ask found a task in: the
    # latest deferred ask's count (any candidate of the session).
    def skip(records)
      records.select { |line| line["kind"] == "judged" && line["stated"] == false }
             .map { |line| line["owner_prompts"].to_i }.max || 0
    end

    # Whether candidate +name+ is asked now, at +owner_prompts+: never twice
    # at one count; unjudged (no ask, or only deferred ones) → yes; one
    # judged ask → once +reask_after_turns+ more owner prompts came; two →
    # done.
    def due?(records, name, owner_prompts:, reask_after_turns:)
      mine = records.select { |line| line["kind"] == "judged" && line["name"] == name }
      return false if mine.any? { |line| line["owner_prompts"].to_i >= owner_prompts }

      judged = mine.select { |line| line["stated"] == true }
      return true if judged.empty?
      return false if judged.size >= 2

      owner_prompts >= judged.first["owner_prompts"].to_i + reask_after_turns
    end

    # The proposed candidates due an ask (+rows+: ContextCandidates
    # .with_status), as Jobs. +texts+ the owner's prompts, oldest first;
    # +parent_attached+ the parent's sources' titles for a delegate child,
    # else nil.
    # @return [Array<Job>]
    def jobs(rows, records, session_id:, texts:, parent_attached:, settings:, phase:)
      owner_prompts = texts.size
      return [] if owner_prompts.zero?

      conversation = conversation(texts, skip: parent_attached ? 0 : skip(records))
      rows.filter_map do |candidate, status|
        next unless status == "proposed"
        next unless due?(records, candidate.name, owner_prompts: owner_prompts,
                                                  reask_after_turns: settings.reask_after_turns)

        Job.new(session_id: session_id, name: candidate.name, title: candidate.title, describe: candidate.describe,
                conversation: conversation, parent_attached: parent_attached, owner_prompts: owner_prompts,
                phase: phase)
      end
    end

    # What on mode would do with +p+: attach (≥ threshold), offer (≥
    # offer_threshold) or none.
    def would(probability, settings)
      return "attach" if probability >= settings.threshold
      return "offer" if probability >= settings.offer_threshold

      "none"
    end

    # One ask (on SideJudgments' thread) and its judged line. No answer
    # (System 1 said nothing: its own warn) writes nothing, so the
    # candidate is asked again at the next owner prompt.
    # @return [Hash, nil] the line's fields
    def ask(client:, job:, log:, settings:, cancel_controller: nil)
      answers = client.ask(state: state(job), questions: questions(child: !job.parent_attached.nil?),
                           cancel_controller: cancel_controller)
      about = answers&.dig(ABOUT_ID)&.noul
      task = answers&.dig(TASK_ID)&.noul
      return nil if about.nil? || task.nil?

      stated = task >= TASK_MIN
      fields = { "title" => job.title, "phase" => job.phase, "owner_prompts" => job.owner_prompts,
                 "p" => about.round(4), "task_p" => task.round(4), "stated" => stated,
                 "would" => stated ? would(about, settings) : nil, "mode" => settings.mode,
                 "threshold" => settings.threshold, "offer_threshold" => settings.offer_threshold,
                 "host" => client.host, "model" => client.model, "child" => job.parent_attached ? true : nil,
                 "conversation" => job.conversation.map { |text| ContextCandidatesLog.short(text) } }
      ContextCandidatesLog.event("judged", session_id: job.session_id, name: job.name, log: log, **fields.transform_keys(&:to_sym))
      fields
    end

    def warn(error)
      Log.warn(:context, "context_judge_failed",
               echo: "[samagotchi:context] candidate judge: #{error.class}: #{error.message}",
               error: error.class.name, msg: error.message.to_s[0, 200])
    end
  end
end
