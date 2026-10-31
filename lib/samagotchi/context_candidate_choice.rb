# frozen_string_literal: true

require_relative "context_candidates"
require_relative "context_candidates_log"
require_relative "context_providers"
require_relative "context_sources"
require_relative "log"

module Samagotchi
  # What becomes of a candidate after the judge (context.candidates.mode
  # on) or the owner chose (docs/context.md, "On mode"):
  #
  # - a judged p ≥ threshold attaches it quietly (#after_judged): the
  #   session's own folder, its why naming the judge without a number; the
  #   worker's next between-turn delivery brings its note, never mid-turn;
  # - offer_threshold ≤ p < threshold shows one card (Attach / Not here),
  #   once per candidate: a `carded` line in ContextCandidatesLog says it
  #   was shown, so a worker restart doesn't show it again;
  # - below, it stays proposed.
  #
  # The card's actions are /context attach NAME and /context decline NAME
  # (#choose), the owner's only: a participant can't send a / line, and a
  # review session refuses them.
  module ContextCandidateChoice
    CARD_SOURCE = "context"
    # The judge's attach, as the source's why (no probability: it is
    # model-visible in the attach note).
    JUDGE_WHY = "it looks related to your task"
    # The owner's attach from the card (or /context attach).
    CHOSEN_WHY = "you attached it"
    OFFER_BODY = "It may be related to your task. Not attached: the agent gets nothing until you attach it."
    USAGE = "usage: /context [attach NAME | decline NAME]"

    module_function

    def card_id(name) = "context-candidate-#{name}"

    # The middle band's card for +candidate+.
    # @return [Hash] Engine#show_card's keywords
    def offer_card(candidate)
      { source: CARD_SOURCE, id: card_id(candidate.name), title: candidate.title.to_s.strip.empty? ? candidate.name : candidate.title,
        body: OFFER_BODY, level: :info,
        actions: [{ label: "Attach", command: "/context attach #{candidate.name}" },
                  { label: "Not here", command: "/context decline #{candidate.name}" }] }
    end

    # The card shown again under its id, with no actions: what became of it.
    def closed_card(candidate, body)
      { source: CARD_SOURCE, id: card_id(candidate.name), title: candidate.title.to_s.strip.empty? ? candidate.name : candidate.title,
        body: body, level: :info, actions: [] }
    end

    # On mode, after a judged ask (ContextJudge.ask's +fields+; nil: no
    # answer): attach, card or nothing. The candidate must still be
    # proposed (the user may have chosen while it was asked).
    # @param show_card [#call] (**card) → shows it; false/nil: it wasn't
    #   shown (the UI is on another session), so no carded line
    # @return [Symbol, nil] :attached, :carded or nil
    def after_judged(job:, fields:, settings:, project_root:, state_dir:, log:, show_card:)
      return nil unless settings.mode == "on" && fields && fields["stated"]
      return nil unless %w[attach offer].include?(fields["would"])

      candidate = proposed(job.session_id, job.name, project_root: project_root, state_dir: state_dir) or return nil
      if fields["would"] == "attach"
        judge_attach(candidate, job: job, p: fields["p"], state_dir: state_dir, log: log, show_card: show_card)
      else
        offer(candidate, job: job, p: fields["p"], log: log, show_card: show_card)
      end
    rescue StandardError => e
      Log.warn(:context, "candidate_choice_failed", name: job.name, error: e.class.name, msg: e.message.to_s[0, 200])
      nil
    end

    # The candidate +name+ when it is still proposed in the session.
    def proposed(session_id, name, project_root:, state_dir:)
      rows = ContextCandidates.with_status(session_id, project_root: project_root, state_dir: state_dir)
      rows.find { |candidate, status| candidate.name == name && status == "proposed" }&.first
    end

    # Whether +name+'s card was shown in the session (a carded line).
    def carded?(log, session_id, name)
      ContextCandidatesLog.records_for(log, session_id).any? { |line| line["kind"] == "carded" && line["name"] == name }
    end

    def judge_attach(candidate, job:, p:, state_dir:, log:, show_card:)
      own = ContextSources.session_location(job.session_id, state_dir: state_dir)
      own.add(ContextCandidates.source_for(candidate, why: JUDGE_WHY))
      Log.info(:context, "candidate_attached", name: candidate.name, trigger: "judge")
      ContextCandidatesLog.event("judge_attached", session_id: job.session_id, name: candidate.name, log: log, p: p)
      # A card from an earlier ask loses its buttons.
      show_card.call(**closed_card(candidate, "Attached: #{JUDGE_WHY}.")) if carded?(log, job.session_id, candidate.name)
      :attached
    rescue ContextSources::Invalid, ContextProviders::Invalid => e
      Log.warn(:context, "candidate_not_attached", name: candidate.name, error: e.message.to_s[0, 200])
      nil
    end

    def offer(candidate, job:, p:, log:, show_card:)
      return nil if carded?(log, job.session_id, candidate.name)
      return nil unless show_card.call(**offer_card(candidate))

      ContextCandidatesLog.event("carded", session_id: job.session_id, name: candidate.name, log: log, p: p)
      :carded
    end

    # /context attach NAME and /context decline NAME (+action+ :attach or
    # :decline) in +session+.
    # @param show_card [#call] (**card) → replaces the card
    # @return [Array(Symbol, String)] :ok or :error, and the answer
    def choose(action, name, session:, state_dir:, show_card:)
      return [:error, "no session yet"] unless session&.id
      return [:error, "a review session takes no context candidates"] if session.review?
      return [:error, USAGE] if name.to_s.empty?

      candidate, status = find(session, name, state_dir: state_dir)
      return [:error, "no candidate #{name} in this session (see /context)"] unless candidate

      action == :attach ? attach(candidate, status, session, state_dir, show_card) : decline(candidate, status, session, state_dir, show_card)
    end

    def find(session, name, state_dir:)
      ContextCandidates.with_status(session.id, project_root: session.project_root, state_dir: state_dir)
                       .find { |candidate, _status| candidate.name == name }
    end

    def attach(candidate, status, session, state_dir, show_card)
      return [:error, "#{candidate.name} is attached already"] if status == "attached"
      if status == "declined"
        return [:error, "#{candidate.name} was declined in this session; chi context add attaches a source by hand"]
      end

      own = ContextSources.session_location(session.id, state_dir: state_dir)
      own.add(ContextCandidates.source_for(candidate, why: CHOSEN_WHY))
      Log.info(:context, "candidate_attached", name: candidate.name, trigger: "command")
      ContextCandidatesLog.event("attached", session_id: session.id, name: candidate.name, state_dir: state_dir, by: "command")
      show_card.call(**closed_card(candidate, "Attached."))
      [:ok, "attached #{candidate.name}: its text comes with your next message"]
    rescue ContextSources::Invalid, ContextProviders::Invalid => e
      [:error, "#{candidate.name} not attached: #{e.message}"]
    end

    def decline(candidate, status, session, state_dir, show_card)
      if status == "attached"
        return [:error, "#{candidate.name} is attached; chi context rm #{candidate.name} removes it"]
      end
      return [:ok, "#{candidate.name} is declined already"] if status == "declined"

      ContextSources.session_location(session.id, state_dir: state_dir).decline(candidate.name, candidate.url.to_s)
      ContextCandidatesLog.event("declined", session_id: session.id, name: candidate.name, state_dir: state_dir, by: "command")
      show_card.call(**closed_card(candidate, "Not attached here."))
      [:ok, "declined #{candidate.name}: not proposed again in this session"]
    end
  end
end
