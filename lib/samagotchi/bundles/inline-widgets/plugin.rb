# frozen_string_literal: true

# The inline-widgets bundle (docs/bundles.md, The inline-widgets bundle): two
# prompt sections that teach the model the ```chi-ui blocks chi web draws
# (docs/internals/inline-widgets.md): picks, rows of options that fill the
# user's reply, and walk, a scenario stepped through. The drawing is core's; this
# bundle only says the blocks exist. Uninstalled, the prompt loses the sections
# and blocks already in a history still draw.
#
# The text is eval 0013's round-2 hint, split in two. It is static, so the
# prompt cache keeps: same text at every build. A delegate child's answer is
# read by its parent, not drawn for a user, a one-shot (-p --non-interactive)
# prints to a terminal, and a review session (chi review) is read by its
# participants, whose page draws no widgets: none of them gets a section. A
# working session the owner pairs in keeps them: the owner's page draws them,
# and a participant invited later mustn't change the prompt (the cache).
class Plugin
  PICKS = <<~TEXT
    The web UI draws fenced ```chi-ui code blocks (YAML inside) as interactive widgets; the terminal shows their source. Use one whenever it helps the user more than prose: a widget replaces the long explanation, it doesn't sit beside one. Never use one for what markdown shows well (tables, lists, key-value). At most one widget per answer; keep the prose around it to a few sentences and don't repeat the widget's content.

    picks: whenever your answer leaves the user two or more things to decide (review findings, a plan's open decisions, which of several fixes to do), even if they didn't ask you to list them. The user clicks one option per row, can add a note, and the UI fills their reply.
    ```chi-ui
    type: picks
    title: What to do with the findings
    rows:
      - id: "1"                       # unique, short; the user's reply names it
        text: Bridge drops the replay buffer on reset    # the item, <= 80 chars
        options:                      # 2-4 short options, one per line
          - fix now
          - skip
          - later
        recommended: fix now          # exactly one of the options
        why: loses events a slow tab still needs        # optional, one short line
    ```
    Every row id unique; a row's options unique. Quote a value that starts with a quote or contains ": ".
  TEXT

  WALK = <<~TEXT
    walk is the other ```chi-ui widget (the same rules: the web UI draws it, at most one widget per answer): a scenario the user steps through one step at a time: who does what, what the user sees, what happens behind it. Use it for "when does this happen / how does this work / what does the user go through" questions.
    ```chi-ui
    type: walk
    title: A tab reconnects
    actors: [user, web, worker]       # 2-5 short ids, unique
    steps:
      - id: s1                        # unique
        actor: user                   # one of actors
        does: reopens the laptop      # the action, <= 80 chars
        sees: the page shows "reconnecting"     # optional: what the user sees at this step
        behind: the tab sends GET /events with Last-Event-ID     # optional: what happens out of sight
      - id: s2
        actor: worker
        does: checks the event id
        cases:                        # optional: the step forks. List EVERY case, the usual one too
          - when: the id is still buffered
            goto: s3
          - when: the id is too old
            goto: s4
      - id: s3
        actor: worker
        does: replays the missed events
        next: end                     # optional: where to go after this step (default: the step below); end ends the walk here
      - id: s4
        actor: web
        does: reloads the whole session
        sees: the page redraws from the top
    ```
    A step needs `does` or `sees` (or both). Steps run in order unless `next` or `cases` say otherwise. Every id unique; every goto names a step; a next names another step or is `end`. Quote a value that starts with a quote or contains ": ".
  TEXT

  def register(chi)
    chi.prompt_section("picks") { |ctx| PICKS if drawn?(ctx) }
    chi.prompt_section("walk") { |ctx| WALK if drawn?(ctx) }
  end

  private

  # Whether the session's answers reach a web page that draws them. Decided by
  # the session's kind, so the same at every build.
  def drawn?(ctx) = ctx.frontend != :one_shot && !ctx.delegate?
end
