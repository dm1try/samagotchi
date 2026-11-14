# frozen_string_literal: true

require "json"
require "tmpdir"
require "spec_helper"
require "samagotchi/worker_link"
require "samagotchi/session_continue"
require "samagotchi/session_chain"
require "samagotchi/objectives"
require "samagotchi/note_delivery"
require "samagotchi/tools/delegate_cursor"
require_relative "support/worker_links"

# SessionContinue.run: the next link of a session chain.
RSpec.describe Samagotchi::SessionContinue, ".run" do
  include WorkerLinks

  let(:manager) { Samagotchi::SessionManager }
  let(:tmpdir) { Dir.mktmpdir("continue-spec") }
  let(:folder) { Dir.mktmpdir("continue-folder") }
  let(:locks) { [] }

  before { allow(Process).to receive(:spawn).and_return(12_345) }

  after do
    locks.each(&:release)
    FileUtils.rm_rf(tmpdir)
    FileUtils.rm_rf(folder)
  end

  def make(prompt: "you are coordinator again", parent_id: nil, delegate: false, status: nil, created: nil)
    Samagotchi::Session.new_session(mode: "assist", model_name: "main:gemma-small", working_directory: folder,
                                    parent_id: parent_id, delegate: delegate).tap do |s|
      s.first_preview = prompt
      s.messages = [{ role: "user", content: prompt }, { role: "assistant", content: "ok" }]
      s.status = status if status
      s.created_at = created if created
      s.save(state_dir: tmpdir)
    end
  end

  def dir_of(id) = Samagotchi::Session.session_dir(id, state_dir: tmpdir)
  def archived?(id) = Samagotchi::ArchiveStore.archived?(dir_of(id))
  def own(id) = locks << Samagotchi::OwnerLock.acquire(dir_of(id), kind: "worker")
  def load(id) = Samagotchi::Session.load(id, state_dir: tmpdir)

  def save_recap(id, text, at: "2026-10-08T17:30:00Z")
    FileUtils.mkdir_p(dir_of(id))
    File.write(File.join(dir_of(id), Samagotchi::RecapStore::FILE), JSON.generate(text: text, created_at: at))
  end

  # The one context note queued for the session.
  def note_of(id)
    notes = Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| Samagotchi::SessionInbox.read_note(f) }
    expect(notes.size).to eq(1)
    notes.first
  end

  def continue(ref, **)
    described_class.run(ref, state_dir: tmpdir, recap_wait: 0, **)
  end

  it "starts the next link in the previous one's folder, model (as typed), llm_context, thinking and reasoning_history levels, appended prompt files, toolkit, and archives the previous one" do
    previous = make(created: "2026-10-08T09:00:00+02:00")
    previous.model_typed = "small"
    previous.llm_context = Samagotchi::LLMContextOverride.new(strategy: [:stale], budget_tokens: 64_000)
    previous.thinking = :low
    previous.reasoning_history = :drop
    previous.appended_prompt_files = ["/r/extra.md"]
    previous.toolkit = Samagotchi::Toolkit.new(name: "coordinator")
    previous.parent_answers = "standard"
    previous.working_set_pins = [{ "kind" => "file", "key" => "/r/lib/a.rb" }]
    previous.save(state_dir: tmpdir)
    save_recap(previous.id, "The user reviewed three PRs and merged two.")
    allow(Samagotchi::HostConfig).to receive(:model_ref).and_call_original
    allow(Samagotchi::HostConfig).to receive(:model_ref).with("small")
                                                         .and_return(Samagotchi::HostConfig.model_ref("main:gemma-small"))

    link = continue(previous.id)

    saved = load(link.id)
    expect(saved).to have_attributes(continues: previous.id, working_directory: folder, model_name: "main:gemma-small",
                                     model_typed: "small", status: Samagotchi::Session::STATUS_IDLE,
                                     first_preview: "you are coordinator again")
    expect(saved.llm_context).to eq(previous.llm_context)
    expect(saved.thinking).to eq(:low)
    expect(saved.reasoning_history).to eq(:drop)
    expect(saved.appended_prompt_files).to eq(["/r/extra.md"])
    expect(saved.toolkit).to eq(Samagotchi::Toolkit.new(name: "coordinator"))
    expect(saved.toolkit_origin).to eq("inherited")
    expect(saved.parent_answers).to eq("standard")
    expect(saved.working_set_pins).to eq([Samagotchi::WorkingSetPin.new(kind: "file", key: "/r/lib/a.rb")])
    expect(archived?(previous.id)).to be(true)
    # Not a descendant: the archive's cascade never reaches the new link.
    expect(archived?(link.id)).to be(false)
    expect(Process).to have_received(:spawn).once

    note = note_of(link.id)
    expect(note[:source]).to eq("session chain")
    as_of = Time.iso8601("2026-10-08T17:30:00Z").localtime.strftime("%Y-%m-%d %H:%M")
    started = Time.iso8601("2026-10-08T09:00:00+02:00").localtime.strftime("%Y-%m-%d %H:%M")
    expect(note[:text]).to eq("This session continues #{previous.id[0, 8]} (#{started}), the previous link of its chain. " \
                              "Its recap, as of #{as_of}:\nThe user reviewed three PRs and merged two." \
                              "\n\nIts last answer:\nok")
  end

  it "keeps the previous link's preloaded and muted memory names" do
    previous = make
    previous.preloaded_memory_names = ["a"]
    previous.muted_memory_names = ["b"]
    previous.save(state_dir: tmpdir)

    link = continue(previous.id)
    saved = load(link.id)

    expect(saved).to have_attributes(preloaded_memory_names: ["a"], muted_memory_names: ["b"])
  end

  it "does not carry a delegate child's reserved memory into a non-delegate continuation" do
    previous = make(parent_id: "parent", delegate: true)
    previous.preloaded_memory_names = %w[system/delegated user/a]
    previous.muted_memory_names = ["user/b"]
    previous.save(state_dir: tmpdir)

    link = continue(previous.id)
    saved = load(link.id)

    expect(saved).to have_attributes(parent_id: nil, preloaded_memory_names: ["user/a"], muted_memory_names: ["user/b"])
    expect(saved.delegate?).to be(false)
  end

  it "sets the new link's opener (not saved) from a previous link that is itself a continuation, nil from a first link" do
    first = make
    second = continue(first.id)
    expect(second.opener).to be_nil
    saved = load(second.id)
    saved.messages += [{ role: "user", content: "check the queue", turn_id: "t1" }, { role: "assistant", content: "ok" }]
    saved.save(state_dir: tmpdir)

    third = continue(second.id)

    expect(third.opener).to eq("check the queue")
    expect(load(third.id).opener).to be_nil
  end

  it "keeps the chain's title on the new link, with or without a first message" do
    previous = make
    previous.title = "Coordinator"
    previous.save(state_dir: tmpdir)

    idle = continue(previous.id)
    prompted = continue(idle.id, prompt: "start the day")

    expect(load(idle.id)).to have_attributes(title: "Coordinator", first_preview: "you are coordinator again")
    expect(load(prompted.id)).to have_attributes(title: "Coordinator", first_preview: "start the day")
    expect(load(continue(make.id).id).title).to be_nil
  end

  it "carries only the link when the previous one has no recap, and runs a first message it was given" do
    previous = make

    link = continue(previous.id, prompt: "start the day")

    expect(note_of(link.id)[:text]).to end_with("the previous link of its chain. It left no recap.\n\nIts last answer:\nok")
    expect(load(link.id)).to have_attributes(last_prompt: "start the day", first_preview: "start the day",
                                             status: Samagotchi::Session::STATUS_RUNNING)
  end

  # A schedule's chain firing: the link's first turn is the schedule's, not
  # the owner's (a person's continue names no sender).
  it "gives the new link's first prompt the sender it was given, none by default" do
    scheduled = continue(make.id, prompt: "the Monday audit", client_id: "system:schedule:0123456789abcdef")
    typed = continue(make.id, prompt: "start the day")

    expect(load(scheduled.id).first_turn_client_id).to eq("system:schedule:0123456789abcdef")
    expect(load(typed.id).first_turn_client_id).to be_nil
  end

  it "asks the previous link's live worker for a recap and carries the one it writes" do
    previous = make
    save_recap(previous.id, "The old recap.")
    client = instance_double(Samagotchi::BridgeClient)
    allow(Samagotchi::WorkerLink).to receive(:client).and_return(client)
    allow(client).to receive(:request_recap) do
      Thread.new do
        sleep 0.3 # sleep-ok: the fresh recap comes a moment after the request
        save_recap(previous.id, "The fresh recap.", at: "2026-10-09T18:00:00Z")
      end
      Samagotchi::BridgeClient::Response.new(status: 200, body: JSON.generate(enabled: true, request: "started"))
    end

    link = continue(previous.id, recap_wait: 5)

    expect(note_of(link.id)[:text]).to end_with(":\nThe fresh recap.\n\nIts last answer:\nok")
  end

  describe "the objectives" do
    let(:list) { Samagotchi::Objectives::List.new.add("Ship it", done_when: "main is green").add("Stay small") }

    def list_note(list, id: "n1")
      Samagotchi::ContextNote.message(note_id: id, text: list.text, source: "objectives",
                                      header: Samagotchi::ContextNote::OBJECTIVES_HEADER, objectives: list.to_payload)
    end

    def with_list(list)
      make.tap do |s|
        s.messages += [list_note(list)]
        s.save(state_dir: tmpdir)
      end
    end

    def notes_of(id)
      Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| Samagotchi::SessionInbox.read_note(f) }
    end

    it "go to the new link as a second note file, after the carry note, as a note the worker frames" do
      link = continue(with_list(list).id)

      carry, objectives = notes_of(link.id)
      expect(carry[:source]).to eq(Samagotchi::SessionChain::NOTE_SOURCE)
      expect(objectives).to include(source: "objectives", header: "OBJECTIVES", text: list.text)
      expect(Samagotchi::Objectives.from_payload(objectives[:objectives])).to eq(list)
    end

    it "take the previous link's unabsorbed newest file over its conversation" do
      previous = with_list(list)
      newer = list.mark("O1", Samagotchi::Objectives::DONE)
      Samagotchi::SessionInbox.write_note(previous.id, text: newer.text, source: "objectives", objectives: newer.to_payload,
                                                       state_dir: tmpdir)

      objectives = notes_of(continue(previous.id).id).last
      expect(Samagotchi::Objectives.from_payload(objectives[:objectives])).to eq(newer)
    end

    it "leave a link's note alone when the previous one has no list" do
      expect(notes_of(continue(make.id).id).size).to eq(1)
    end

    it "carry over from an older chi's review link as from any link" do
      previous = with_list(list)
      previous.review = Samagotchi::SessionReview.new(subjects: ["a.rb"])
      previous.save(state_dir: tmpdir)

      expect(notes_of(continue(previous.id).id).size).to eq(2)
    end

    it "fail alone: a list that can't be read logs and the continue goes on" do
      previous = with_list(list)
      allow(Samagotchi::Objectives).to receive(:current).and_raise(Errno::EACCES)
      allow(Samagotchi::Log).to receive(:warn)

      link = continue(previous.id)

      expect(notes_of(link.id).size).to eq(1)
      expect(Samagotchi::Log).to have_received(:warn).with(:worker, "continue_objectives_failed", hash_including(sid: previous.id))
    end
  end

  describe "the carry note's last answer" do
    let(:marker) { "\n\nIts last answer:\n" }
    let(:limit) { Samagotchi::SessionInbox::NOTE_MAX_BYTES }

    def with_messages(*messages)
      make.tap do |s|
        s.messages = [{ role: "user", content: "wrap up" }, *messages]
        s.save(state_dir: tmpdir)
      end
    end

    def note_after_continue(previous) = note_of(continue(previous.id).id)[:text]
    def carried(previous) = note_after_continue(previous).split(marker, 2)[1]
    def answer(text, **rest) = { role: "assistant", content: text, **rest }

    it "keeps the end of a long answer, to the exact character cap" do
      text = "start #{"x" * 5000} next: merge abc123"

      carried_text = carried(with_messages(answer(text)))

      expect(carried_text.length).to eq(Samagotchi::SessionChain::LAST_ANSWER_CHARS)
      expect(carried_text).to start_with("…x").and end_with("next: merge abc123")
    end

    it "takes an answer of exactly the cap whole" do
      text = "y" * Samagotchi::SessionChain::LAST_ANSWER_CHARS

      expect(carried(with_messages(answer(text)))).to eq(text)
    end

    it "strips thinking and wire markup, and keeps a cut reply's [interrupted]" do
      expect(carried(with_messages(answer("<think>hmm</think>Done: abc123.\n\n[interrupted]"))))
        .to eq("Done: abc123.\n\n[interrupted]")
    end

    it "takes the content, not a hook's display" do
      expect(carried(with_messages(answer("the words", display: "<b>shown</b>")))).to eq("the words")
    end

    it "stays the last word after a !shell line the user ran" do
      expect(carried(with_messages(answer("Done."), { role: "user", content: "!(git log)\nabc" }))).to eq("Done.")
    end

    it "scrubs invalid bytes on disk instead of losing the answer" do
      previous = with_messages(answer("broken"))
      file = File.join(tmpdir, "#{previous.id}.json")
      File.binwrite(file, File.binread(file).sub('"broken"', "\"bro\xFFken\"".b))

      expect(carried(previous)).to eq("bro\uFFFDken")
    end

    {
      "an empty conversation" => [],
      "only tool calls" => [{ role: "assistant", content: "", tool_calls: [{ id: "c1" }] }],
      "a narration step that asked for tools" => [{ role: "assistant", content: "Now reading.", tool_calls: [{ id: "c1" }] }],
      "a later turn that failed" => [{ role: "assistant", content: "old" }, { role: "user", content: "next", turn_id: "t2" }],
      "a later tool response" => [{ role: "assistant", content: "old" }, { role: "tool_response", content: "out" }],
      "non-String content" => [{ role: "assistant", content: [{ type: "text", text: "parts" }] }]
    }.each do |what, messages|
      it "gives no answer for #{what}" do
        previous = make
        previous.messages = messages
        previous.save(state_dir: tmpdir)

        expect(note_after_continue(previous)).to end_with("It left no recap.")
      end
    end

    it "carries the answer of an older chi's review link as any link's" do
      previous = with_messages(answer("for this link's participants"))
      previous.review = Samagotchi::SessionReview.new(subjects: ["docs/plan.md"])
      previous.save(state_dir: tmpdir)

      expect(note_after_continue(previous)).to include("for this link's participants")
    end

    it "continues with no answer, logging why, when the previous link's file can't be read any more" do
      previous = with_messages(answer("gone"))
      allow(manager).to receive(:archive_session).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { File.write(File.join(tmpdir, "#{previous.id}.json"), "{not json") }
      end
      allow(Samagotchi::Log).to receive(:warn)

      link = continue(previous.id)

      expect(note_of(link.id)[:text]).to end_with("It left no recap.")
      expect(Samagotchi::Log).to have_received(:warn).with(:worker, "continue_last_answer_failed", hash_including(sid: previous.id))
    end

    it "carries the newer answer of a turn that finished during the recap wait" do
      previous = with_messages(answer("before the wait"))
      allow(described_class).to receive(:recap_before_archive) do
        fresh = load(previous.id)
        fresh.messages += [{ role: "user", content: "one more", turn_id: "t2" }, answer("after the wait")]
        fresh.save(state_dir: tmpdir)
      end

      expect(carried(previous)).to eq("after the wait")
    end

    it "continues on an 8000-character CJK recap and a long answer, within the note's limit" do
      previous = with_messages(answer("答" * 5000))
      save_recap(previous.id, "概" * Samagotchi::SessionChain::RECAP_CHARS)

      text = note_after_continue(previous)

      expect(text.bytesize).to be <= limit
      expect(text).to be_valid_encoding
      expect(archived?(previous.id)).to be(true)
    end

    it "cuts a Cyrillic answer near the limit on a character, keeping its end" do
      previous = with_messages(answer("начало #{"я" * 3900} дальше: слить"))
      save_recap(previous.id, "р" * Samagotchi::SessionChain::RECAP_CHARS)

      text = note_after_continue(previous)
      carried_text = text.split(marker, 2)[1]

      expect(text.bytesize).to be_between(limit - 1, limit)
      expect(carried_text).to be_valid_encoding
      expect(carried_text).to start_with("…я").and end_with("дальше: слить")
    end

    it "takes the answer whole when it just fits" do
      recap_chars = 7000
      previous = make
      save_recap(previous.id, "р" * recap_chars)
      head = Samagotchi::SessionChain.note_text(previous, recap: Samagotchi::RecapStore.read(dir_of(previous.id)), state_dir: tmpdir)
                                     .split(marker, 2)[0]
      room = limit - head.bytesize - marker.bytesize
      text = "ж" * (room / 2)
      previous.messages = [answer(text)]
      previous.save(state_dir: tmpdir)

      expect(carried(previous)).to eq(text)
    end

    describe "session.carry_last_answer" do
      def setting(value)
        allow(Samagotchi::Config).to receive(:get).and_call_original
        allow(Samagotchi::Config).to receive(:get).with("session.carry_last_answer").and_return(value)
      end

      it "is on by default" do
        expect(Samagotchi::Config.get("session.carry_last_answer")).to be(true)
        expect(carried(with_messages(answer("kept")))).to eq("kept")
      end

      it "gives the recap-only note when off" do
        setting(false)
        previous = with_messages(answer("left out"))
        save_recap(previous.id, "The recap.")

        expect(note_after_continue(previous)).to end_with(":\nThe recap.")
      end

      it "still holds an oversized recap to the note's limit when off" do
        setting(false)
        previous = make
        save_recap(previous.id, "概" * Samagotchi::SessionChain::RECAP_CHARS)

        text = note_after_continue(previous)

        expect(text.bytesize).to be <= limit
        expect(text).to end_with("…")
      end
    end
  end

  describe "the previous link's notes" do
    def notes_of(id)
      Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| Samagotchi::SessionInbox.read_note(f) }
    end

    it "move to the new link, names kept, ahead of its chain note" do
      previous = make
      path = Samagotchi::SessionInbox.write_note(previous.id, text: "deploy frozen", state_dir: tmpdir)

      link = continue(previous.id)

      expect(notes_of(previous.id)).to eq([])
      waiting, chain = notes_of(link.id)
      expect(waiting).to include(text: "deploy frozen", source: "cli", note_id: File.basename(path, ".json"))
      expect(chain[:source]).to eq(Samagotchi::SessionChain::NOTE_SOURCE)
    end

    it "move after the objectives' carry: a pending /objectives edit reaches the new link's list" do
      list = Samagotchi::Objectives::List.new.add("Ship it")
      previous = make
      previous.messages += [Samagotchi::ContextNote.message(note_id: "n1", text: list.text, source: "objectives",
                                                            header: Samagotchi::ContextNote::OBJECTIVES_HEADER,
                                                            objectives: list.to_payload)]
      previous.save(state_dir: tmpdir)
      edited = list.add("Stay small")
      Samagotchi::SessionInbox.write_note(previous.id, text: edited.text, source: "objectives",
                                                       objectives: edited.to_payload, state_dir: tmpdir)

      link = continue(previous.id)

      lists = notes_of(link.id).select { |n| n[:objectives] }
      expect(lists.size).to eq(1)
      expect(Samagotchi::Objectives.from_payload(lists.last[:objectives])).to eq(edited)
    end

    it "take a note an old worker claimed and never absorbed, un-claimed, logging it" do
      previous = make
      Samagotchi::SessionInbox.claim_note_file(Samagotchi::SessionInbox.write_note(previous.id, text: "taken", state_dir: tmpdir))
      allow(Samagotchi::Log).to receive(:info).and_call_original

      link = continue(previous.id)

      expect(notes_of(previous.id)).to eq([])
      expect(Samagotchi::SessionInbox.find_new_note_files(dir_of(link.id)).map { |f| File.extname(f) }).to eq([".json"] * 2)
      expect(notes_of(link.id).map { |n| n[:text] }.first).to eq("taken")
      expect(Samagotchi::Log).to have_received(:info).with(:worker, "notes_moved_claimed", hash_including(count: 1))
    end

    it "go back when the new link's worker fails to spawn, with a note sent to the new link meanwhile" do
      previous = make
      Samagotchi::SessionInbox.write_note(previous.id, text: "waiting", state_dir: tmpdir)
      allow(Process).to receive(:spawn) do
        link = Samagotchi::SessionChain.next_of(previous.id, state_dir: tmpdir)
        Samagotchi::NoteDelivery.deliver(previous.id, text: "sent during the start", source: "slack", state_dir: tmpdir)
        expect(notes_of(link).map { |n| n[:text] }).to include("waiting", "sent during the start")
        raise Errno::EAGAIN
      end

      expect { continue(previous.id) }.to raise_error(Errno::EAGAIN)

      expect(notes_of(previous.id).map { |n| n[:text] }).to eq(["waiting", "sent during the start"])
      expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id)).to eq([previous.id])
    end

    it "rolls back an interruption before the successor is saved" do
      previous = make
      intent_path = File.join(dir_of(previous.id), "continue.json")
      allow(manager).to receive(:spawn_session) do
        expect(JSON.parse(File.read(intent_path))).to include("successor_id" => match(/\A[0-9a-f-]{36}\z/))
        raise Interrupt, "interrupted before successor save"
      end

      expect { continue(previous.id) }.to raise_error(Interrupt, "interrupted before successor save")
      expect(archived?(previous.id)).to be(false)
      expect(File.exist?(intent_path)).to be(false)

      listed = manager.list_sessions(state_dir: tmpdir)

      expect(listed.map(&:id)).to include(previous.id)
    end

    it "unarchives delegates that were archived with an interrupted continuation" do
      previous = make
      child = make(parent_id: previous.id, delegate: true)
      intent_path = File.join(dir_of(previous.id), Samagotchi::SessionContinue::CONTINUE_INTENT)
      FileUtils.mkdir_p(dir_of(previous.id))
      File.write(intent_path, JSON.generate(successor_id: SecureRandom.uuid, previously_archived: []))
      [previous, child].each { |session| Samagotchi::ArchiveStore.archive(session.id, state_dir: tmpdir) }

      described_class.repair_interrupted(state_dir: tmpdir)

      expect([previous, child].map { |session| archived?(session.id) }).to eq([false, false])
      expect(File.exist?(intent_path)).to be(false)
    end

    it "moves a corrupt continuation intent aside and warns once" do
      previous = make
      intent_path = File.join(dir_of(previous.id), Samagotchi::SessionContinue::CONTINUE_INTENT)
      FileUtils.mkdir_p(File.dirname(intent_path))
      File.write(intent_path, "{broken")
      expect(Samagotchi::Log).to receive(:warn).with(
        :worker, "continue_repair_failed", hash_including(sid: previous.id, path: intent_path)
      ).once

      2.times { described_class.repair_interrupted(state_dir: tmpdir) }

      expect(File.exist?(intent_path)).to be(false)
      expect(File.exist?("#{intent_path}.bad")).to be(true)
    end

    it "moves the intent aside when its session file is corrupt" do
      previous = make
      intent_path = File.join(dir_of(previous.id), Samagotchi::SessionContinue::CONTINUE_INTENT)
      FileUtils.mkdir_p(File.dirname(intent_path))
      File.write(intent_path, JSON.generate(successor_id: SecureRandom.uuid))
      File.write(Samagotchi::Session.session_file(previous.id, state_dir: tmpdir), "{broken")
      expect(Samagotchi::Log).to receive(:warn).with(
        :worker, "continue_repair_failed", hash_including(sid: previous.id, path: intent_path)
      ).once

      2.times { described_class.repair_interrupted(state_dir: tmpdir) }

      expect(File.exist?(intent_path)).to be(false)
      expect(File.exist?("#{intent_path}.bad")).to be(true)
    end

    it "does not read session JSON when there are no continuation intents" do
      make
      expect(Samagotchi::Session).not_to receive(:list)
      expect(Samagotchi::Session).not_to receive(:load)

      described_class.repair_interrupted(state_dir: tmpdir)
    end

    it "go back with one sent to the previous link after the give-back, and with an older chi's late write" do
      previous = make
      allow(Process).to receive(:spawn).and_raise(Errno::EAGAIN)
      orphan = nil
      allow(Samagotchi::NoteMove).to receive(:give_back).and_wrap_original do |original, **kwargs|
        first = orphan.nil?
        orphan ||= kwargs[:from]
        original.call(**kwargs).tap do
          # Before the link is deleted: it is out of the chain already.
          if first
            Samagotchi::NoteDelivery.deliver(previous.id, text: "sent as it was undone", source: "slack", state_dir: tmpdir)
          end
        end
      end
      allow(manager).to receive(:delete_session).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap do
          # An older chi, which resolved the link earlier, writes after the delete.
          dir = File.join(dir_of(orphan), "notes")
          FileUtils.mkdir_p(dir)
          File.write(File.join(dir, "20991231000000000000000-abcdef.json"),
                     JSON.generate("text" => "late", "source" => "cli", "created_at" => Time.now.iso8601))
        end
      end

      expect { continue(previous.id) }.to raise_error(Errno::EAGAIN)

      expect(notes_of(previous.id).map { |n| n[:text] }).to eq(["sent as it was undone", "late"])
      expect(Dir.exist?(dir_of(orphan))).to be(false)
    end
  end

  it "archives the previous link's finished delegates with it" do
    previous = make
    child = make(prompt: "count the specs", parent_id: previous.id, delegate: true)
    Samagotchi::SessionInbox.write_output(dir_of(child.id), "42 specs")
    reply = Dir.children(File.join(dir_of(child.id), "output")).first
    Samagotchi::Tools::DelegateCursors.update(previous.id, child.id, state_dir: tmpdir) { |c| c.with(reply_file: reply) }

    link = continue(previous.id)

    expect([previous.id, child.id].map { |id| archived?(id) }).to eq([true, true])
    expect(archived?(link.id)).to be(false)
  end

  describe "moving the attached context to the new link" do
    let(:previous) { make }
    let(:ids) { [] }

    after { ids.each { |id| Samagotchi::ContextSources.remove_session(id, state_dir: tmpdir) } }

    def location(id) = Samagotchi::ContextSources.session_location(id, state_dir: tmpdir)

    def fetched(text) = Samagotchi::ContextSources::Fetched.new(text: text, summary: nil, wake: false, hint: nil)

    def add_context_source(location, name, cmd: nil)
      location.add(Samagotchi::ContextSources::Source.new(name: name, cmd: cmd, every_seconds: nil, why: nil, hint: nil,
                                                          scope: "session", added_by: "spec", created_at: nil))
    end

    def notes_of(id)
      Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| Samagotchi::SessionInbox.read_note(f) }
    end

    it "moves a command source, leaves a pushed one, and writes a second note after the chain's" do
      ids << previous.id
      old = location(previous.id)
      old.add(Samagotchi::ContextSources::Source.new(name: "ci", cmd: "echo ok", every_seconds: nil, why: nil,
                                                     hint: nil, scope: nil, added_by: "cli", created_at: nil))
      old.record_text("ci", fetched("green"))
      old.add(Samagotchi::ContextSources::Source.new(name: "notes", cmd: nil, every_seconds: nil, why: nil, hint: nil,
                                                     scope: nil, added_by: "cli", created_at: nil))

      link = continue(previous.id)
      ids << link.id

      expect(location(link.id).sources.map(&:name)).to eq(["ci"])
      expect(location(link.id).snapshot("ci").text).to eq("green")
      expect(link.moved_context).to have_attributes(moved: ["ci"])
      expect(link.moved_context.stayed.map(&:name)).to eq(["notes"])
      notes = notes_of(link.id)
      expect(notes.map { |n| n[:source] }).to eq([Samagotchi::SessionChain::NOTE_SOURCE, Samagotchi::ContextMove::NOTE_SOURCE])
      expect(notes.last[:text])
        .to eq("Context moved with this session: ci. Left with #{previous.id[0, 8]}: notes (pushed).")
    end

    it "keeps a peer's pairing left behind in the link's left.json, and says what chi does about it" do
      ids << previous.id
      old = location(previous.id)
      old.add(Samagotchi::ContextSources::Source.new(name: "claude-inbox", cmd: nil, every_seconds: nil, why: nil,
                                                     hint: "/tmp/c.sock", scope: nil, added_by: "cli", created_at: nil))

      link = continue(previous.id)
      ids << link.id

      expect(location(link.id).left.map(&:to_h)).to eq([{ "name" => "claude-inbox", "hint" => "/tmp/c.sock",
                                                          "from" => previous.id }])
      expect(notes_of(link.id).last[:text]).to eq(
        "Left with #{previous.id[0, 8]}: claude-inbox (Claude's pairing: chi asks Claude to pair again with this session)."
      )
    end

    it "carries unabsorbed pushed text as a separate third-party context note" do
      ids << previous.id
      old = location(previous.id)
      add_context_source(old, "notes")
      old.record_text("notes", fetched("the peer's unanswered answer"))
      old.update_subscription("notes") { |sub| sub.with(seen: "an older revision") }

      link = continue(previous.id)
      ids << link.id

      notes = notes_of(link.id)
      expect(notes.map { |note| note[:source] }).to eq(
        [Samagotchi::SessionChain::NOTE_SOURCE, Samagotchi::ContextMove::NOTE_SOURCE, Samagotchi::ContextMove::NOTE_SOURCE]
      )
      expect(notes.last[:text]).to include("third-party", "not instructions", "Source: notes",
                                           "the peer's unanswered answer")
      expect(location(link.id).left.map(&:name)).to eq(["notes"])
    end

    it "does not carry seen, read, empty, command-source, or forked pushed text" do
      ids << previous.id
      old = location(previous.id)
      %w[seen read empty].each { |name| add_context_source(old, name) }
      seen = old.record_text("seen", fetched("already absorbed"))
      read = old.record_text("read", fetched("explicitly read"))
      old.record_text("command", fetched("command result"))
      add_context_source(old, "command", cmd: "printf command")
      old.update_subscription("seen") { |sub| sub.with(seen: seen.revision) }
      old.update_subscription("read") { |sub| sub.with(read: read.revision) }
      fork = make
      ids << fork.id

      Samagotchi::ContextMove.call(from: previous.id, to: fork.id, mode: :fork, state_dir: tmpdir)

      expect(notes_of(fork.id).map { |note| note[:source] }).to eq([Samagotchi::ContextMove::NOTE_SOURCE])
      expect(notes_of(fork.id).first[:text]).not_to include("explicitly read", "already absorbed")

      link = continue(previous.id)
      ids << link.id

      expect(notes_of(link.id).map { |note| note[:source] })
        .to eq([Samagotchi::SessionChain::NOTE_SOURCE, Samagotchi::ContextMove::NOTE_SOURCE])
    end

    it "bounds pushed text and the aggregate carry note on UTF-8 character boundaries" do
      ids << previous.id
      old = location(previous.id)
      add_context_source(old, "a")
      old.record_text("a", fetched("é" * 20_000))

      link = continue(previous.id)
      ids << link.id
      note = notes_of(link.id).last

      expect(note[:text].bytesize).to be < Samagotchi::SessionInbox::NOTE_MAX_BYTES
      expect(note[:text].valid_encoding?).to be(true)
      expect(note[:text]).to include("truncated")
    end

    it "marks an aggregate cut when many pushed sources exceed the carry-note budget" do
      ids << previous.id
      old = location(previous.id)
      %w[a b c d e f g].each do |name|
        add_context_source(old, name)
        old.record_text(name, fetched("answer " * 400))
      end

      link = continue(previous.id)
      ids << link.id
      note = notes_of(link.id).last

      expect(note[:text].bytesize).to be <= Samagotchi::ContextMove::CARRY_NOTE_MAX_BYTES
      expect(note[:text].bytesize).to be < Samagotchi::SessionInbox::NOTE_MAX_BYTES
      expect(note[:text]).to include("additional pushed text omitted")
      expect(note[:text].valid_encoding?).to be(true)
    end

    it "carries the next pushed source after one is cut by the per-source cap" do
      ids << previous.id
      old = location(previous.id)
      %w[a b].each { |name| add_context_source(old, name) }
      old.record_text("a", fetched("answer " * 1500))
      old.record_text("b", fetched("the short answer"))

      link = continue(previous.id)
      ids << link.id
      note = notes_of(link.id).last

      expect(note[:text]).to include("Source: a", "Source: b", "the short answer")
      expect(note[:text]).not_to include("additional pushed text omitted")
      first_source = note[:text].split("\nSource: b\n").first
      expect(first_source).to end_with(Samagotchi::ContextMove::CARRY_SOURCE_TRUNCATION)
      expect(note[:text].bytesize).to be <= Samagotchi::ContextMove::CARRY_NOTE_MAX_BYTES
    end

    it "stops at the source that does not fit the note and marks the rest as omitted" do
      ids << previous.id
      old = location(previous.id)
      %w[a b c d e].each do |name|
        add_context_source(old, name)
        old.record_text(name, fetched("x" * 5000))
      end

      link = continue(previous.id)
      ids << link.id
      note = notes_of(link.id).last

      expect(note[:text].bytesize).to be <= Samagotchi::ContextMove::CARRY_NOTE_MAX_BYTES
      expect(note[:text]).to end_with(Samagotchi::ContextMove::CARRY_MORE_TRUNCATION)
      expect(note[:text]).not_to include("Source: e")
    end

    it "keeps the small sources that fit the room left after the big ones fill the note" do
      ids << previous.id
      old = location(previous.id)
      %w[a b c d e].each { |name| add_context_source(old, name) }
      %w[a b c].each { |name| old.record_text(name, fetched("answer " * 1500)) }
      %w[d e].each { |name| old.record_text(name, fetched("tail of #{name}")) }

      link = continue(previous.id)
      ids << link.id
      note = notes_of(link.id).last

      expect(note[:text]).to include("Source: a", "Source: b", "Source: c", "Source: d", "Source: e")
      expect(note[:text]).to include("tail of d", "tail of e")
      expect(note[:text]).not_to include("additional pushed text omitted")
      expect(note[:text].bytesize).to be <= Samagotchi::ContextMove::CARRY_NOTE_MAX_BYTES
    end

    it "marks the omitted line when the last source has no room left in the note" do
      ids << previous.id
      old = location(previous.id)
      %w[a b c d tail].each { |name| add_context_source(old, name) }
      %w[a b d].each { |name| old.record_text(name, fetched("z" * 4096)) }
      old.record_text("c", fetched("c" * 2869))
      old.record_text("tail", fetched("the last source"))

      link = continue(previous.id)
      ids << link.id
      note = notes_of(link.id).last

      expect(note[:text]).to end_with(Samagotchi::ContextMove::CARRY_MORE_TRUNCATION)
      expect(note[:text]).not_to include("Source: tail")
      expect(note[:text]).to include("Source: d")
      expect(note[:text].bytesize).to be <= Samagotchi::ContextMove::CARRY_NOTE_MAX_BYTES
    end

    it "keeps the ordinary moved-context note when carrying pushed text fails" do
      ids << previous.id
      old = location(previous.id)
      add_context_source(old, "notes")
      old.record_text("notes", fetched("unabsorbed"))
      to = make
      ids << to.id
      writes = 0
      allow(Samagotchi::SessionInbox).to receive(:write_note).and_wrap_original do |original, *args, **kwargs|
        writes += 1
        raise IOError, "carry failed" if writes == 2

        original.call(*args, **kwargs)
      end
      expect(Samagotchi::Log).to receive(:warn)
        .with(:context, "context_move_carry_failed", hash_including(sid: to.id, error: "IOError"))

      Samagotchi::ContextMove.call(from: previous.id, to: to.id, mode: :continue, state_dir: tmpdir)

      expect(notes_of(to.id).map { |note| note[:source] }).to eq([Samagotchi::ContextMove::NOTE_SOURCE])
      expect(notes_of(to.id).first[:text]).to include("Left with")
    end

    it "writes no second note when there is no context" do
      link = continue(previous.id)

      expect(notes_of(link.id).size).to eq(1)
      expect(link.moved_context).to eq(Samagotchi::ContextSources::Moved.none)
    end
  end

  describe "moving the open delegates to the new link" do
    def cursors(id) = Samagotchi::Tools::DelegateCursors.read(id, state_dir: tmpdir)
    def rings(id) = Samagotchi::SessionInbox.find_ring_files(dir_of(id))
    def ring_ids(id) = rings(id).map { |f| Samagotchi::SessionInbox.read_ring(f)[:child_id] }

    def started(parent, child)
      Samagotchi::Tools::DelegateWait.mark_started(parent.id, child, state_dir: tmpdir)
    end

    # A child's notes, by source.
    def notes_of(id)
      Samagotchi::SessionInbox.find_new_note_files(dir_of(id)).map { |f| Samagotchi::SessionInbox.read_note(f) }
    end

    it "moves running, live and unreported delegates and an open grandchild's delegate; archives the finished one" do
      # The stand-in starter (12_345) still runs.
      allow(Process).to receive(:waitpid).and_return(nil)
      previous = make
      running = make(prompt: "a", parent_id: previous.id, delegate: true, status: Samagotchi::Session::STATUS_RUNNING)
      own(running.id)
      live = make(prompt: "b", parent_id: previous.id, delegate: true)
      own(live.id)
      unreported = make(prompt: "c", parent_id: previous.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(unreported.id), "done")
      middle = make(prompt: "d", parent_id: previous.id, delegate: true)
      grandchild = make(prompt: "e", parent_id: middle.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(grandchild.id), "done")
      finished = make(prompt: "f", parent_id: previous.id, delegate: true)
      [running, live, unreported, finished].each { |c| started(previous, c) }
      Samagotchi::SessionInbox.write_ring(dir_of(previous.id), child_id: unreported.id, why: "turn_end")
      moved = [running, live, unreported, middle].map(&:id)

      link = continue(previous.id)

      expect(link.moved_children).to match_array(moved)
      expect(manager.children_of(link.id, state_dir: tmpdir).map(&:id)).to match_array(moved)
      moved.each do |id|
        expect(Samagotchi::Session.parent_override(id, state_dir: tmpdir)).to eq(link.id)
        expect(archived?(id)).to be(false)
        expect(notes_of(id).map { |n| n[:text] }).to eq(["Your parent session is now #{link.id[0, 8]} (#{link.id}), " \
                                                          "the next link of its session chain: send notes there, " \
                                                          "and your reports reach it."])
      end
      expect(load(grandchild.id).parent_id).to eq(middle.id)
      expect(archived?(grandchild.id)).to be(false)
      expect([archived?(previous.id), archived?(finished.id)]).to eq([true, true])
      expect(load(finished.id).parent_id).to eq(previous.id)
      # Cursors copied (the previous link keeps its own), rings moved.
      expect(cursors(link.id).keys).to match_array([running, live, unreported].map(&:id))
      expect(cursors(previous.id).keys).to include(finished.id, unreported.id)
      expect(ring_ids(link.id)).to eq([unreported.id])
      expect(rings(previous.id)).to be_empty
      # The move is done: no intent. The starting marker stays, naming the
      # worker's starter, until the spawned worker holds the link
      # (Worker#start clears it).
      expect(Samagotchi::ChildMove.read_intent(link.id, state_dir: tmpdir)).to be_nil
      expect(JSON.parse(File.read(File.join(dir_of(link.id), Samagotchi::StartingMarker::FILE)))).to include("pid" => 12_345)
      expect(Process).to have_received(:spawn).once
      expect(Samagotchi::ChildrenStatus.counts(link.id, state_dir: tmpdir))
        .to have_attributes(running: 1, unreported: 1)
    end

    it "lists a moved child under the new link even after its live worker saves its stale copy" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      own(child.id)
      held = load(child.id)

      link = continue(previous.id)
      held.save(state_dir: tmpdir)

      expect(JSON.parse(File.read(File.join(tmpdir, "#{child.id}.json")))["parent_id"]).to eq(previous.id)
      expect(Samagotchi::Session.list(state_dir: tmpdir).find { |s| s.id == child.id }.parent_id).to eq(link.id)
      expect(manager.children_of(link.id, state_dir: tmpdir).map(&:id)).to eq([child.id])
      expect(manager.children_of(previous.id, state_dir: tmpdir)).to be_empty
    end

    it "moves a delegate started during the recap wait too" do
      previous = make
      late = nil
      allow(described_class).to receive(:recap_before_archive) do
        late = make(prompt: "late", parent_id: previous.id, delegate: true)
        Samagotchi::SessionInbox.write_output(dir_of(late.id), "done")
      end

      link = continue(previous.id)

      expect(link.moved_children).to eq([late.id])
      expect(load(late.id).parent_id).to eq(link.id)
      expect(archived?(late.id)).to be(false)
    end

    it "takes a ring a moved child writes between its override and the spawn once, and spawns one worker" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      started(previous, child)
      Samagotchi::SessionInbox.write_output(dir_of(child.id), "found it")
      allow(Samagotchi::Session).to receive(:reparent).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap do
          # The child's turn ends now, in its own process: it rings and wakes.
          Samagotchi::ChildRing.ring(load(child.id), why: "turn_end", state_dir: tmpdir)
          Samagotchi::ChildRing.await_wakes
        end
      end
      allow(manager).to receive(:start_for_inbox).and_call_original

      link = continue(previous.id)

      # The ring's wake found the new link starting: its own spawn reads it.
      expect(manager).not_to have_received(:start_for_inbox)
      expect(Process).to have_received(:spawn).once
      expect(ring_ids(link.id)).to eq([child.id])
      reports = Samagotchi::ChildReports.new(session_id: link.id, state_dir: tmpdir, predecessor: previous.id).take
      expect(reports.map(&:child_id)).to eq([child.id])
    end

    it "continues again after a crash between the archive and the new link (crash 1): the delegates move then" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
      Samagotchi::ArchiveStore.archive(previous.id, state_dir: tmpdir)

      link = continue(previous.id)

      expect(load(child.id).parent_id).to eq(link.id)
      expect([archived?(previous.id), archived?(child.id)]).to eq([true, false])
    end

    it "moves the delegates back when the new link's worker fails to spawn" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
      Samagotchi::SessionInbox.write_ring(dir_of(previous.id), child_id: child.id, why: "turn_end")
      allow(Process).to receive(:spawn).and_raise(Errno::EAGAIN)

      expect { continue(previous.id) }.to raise_error(Errno::EAGAIN)

      expect(load(child.id).parent_id).to eq(previous.id)
      expect(ring_ids(previous.id)).to eq([child.id])
      expect([archived?(previous.id), archived?(child.id)]).to eq([false, false])
      expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id))
        .to contain_exactly(previous.id, child.id)
      expect(notes_of(child.id).last[:text]).to start_with("Your parent session is #{previous.id[0, 8]} (#{previous.id}) " \
                                                           "again: the continue that moved you to its next link failed.")
    end

    it "undoes the move and gives notes back when interrupted after saving the successor" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
      Samagotchi::SessionInbox.write_note(previous.id, text: "waiting", state_dir: tmpdir)
      allow(manager).to receive(:spawn_session).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs)
        raise Interrupt, "interrupted after successor save"
      end

      expect { continue(previous.id) }.to raise_error(Interrupt, "interrupted after successor save")

      expect(load(child.id).parent_id).to eq(previous.id)
      expect(notes_of(previous.id).map { |note| note[:text] }).to include("waiting")
      expect([archived?(previous.id), archived?(child.id)]).to eq([false, false])
      expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id))
        .to contain_exactly(previous.id, child.id)
    end

    it "gives back a ring a child wrote into the failed link as it was moved back, and wakes the previous link for it" do
      previous = make
      child = make(prompt: "a", parent_id: previous.id, delegate: true)
      Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
      allow(Process).to receive(:spawn).and_raise(Errno::EAGAIN)
      allow(Samagotchi::ChildMove).to receive(:apply).and_wrap_original do |original, ids, **kwargs|
        original.call(ids, **kwargs).tap do
          # The child read the override just before the undo wrote it back.
          Samagotchi::SessionInbox.write_ring(dir_of(kwargs[:from]), child_id: child.id, why: "turn_end") if kwargs[:undo]
        end
      end
      allow(manager).to receive(:wake_for_report)

      expect { continue(previous.id) }.to raise_error(Errno::EAGAIN)

      expect(ring_ids(previous.id)).to eq([child.id])
      expect(manager).to have_received(:wake_for_report).with(previous.id, state_dir: tmpdir)
    end

    describe "a failure once the new link's worker exists" do
      let(:link_locks) { [] }

      before do
        allow(manager).to receive(:spawn_worker_for_session) do |session, **|
          link_locks << Samagotchi::OwnerLock.acquire(dir_of(session.id), kind: "worker")
          raise IOError, "spawned, then failed"
        end
      end

      after { link_locks.each(&:release) }

      it "stops that worker, deletes the link and moves the delegates back" do
        previous = make
        child = make(prompt: "a", parent_id: previous.id, delegate: true)
        Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
        allow(manager).to receive(:stop_session) do
          link_locks.each(&:release)
          true
        end

        expect { continue(previous.id) }.to raise_error(IOError)

        expect(manager).to have_received(:stop_session).once
        expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id))
          .to contain_exactly(previous.id, child.id)
        expect(load(child.id).parent_id).to eq(previous.id)
        expect(archived?(previous.id)).to be(false)
      end

      it "raises DeleteRefused when that worker outlives the stop, with the delegates back and nothing archived" do
        previous = make
        child = make(prompt: "a", parent_id: previous.id, delegate: true)
        Samagotchi::SessionInbox.write_output(dir_of(child.id), "done")
        allow(manager).to receive(:stop_session).and_return(false)

        expect { continue(previous.id) }.to raise_error(manager::DeleteRefused, /still shutting down/)

        expect(load(child.id).parent_id).to eq(previous.id)
        expect([archived?(previous.id), archived?(child.id)]).to eq([false, false])
      end
    end
  end

  describe "refusals, which start nothing and archive nothing" do
    def expect_nothing_started(previous)
      expect(Process).not_to have_received(:spawn)
      expect(archived?(previous.id)).to be(false)
      expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:continues).compact).to be_empty
    end

    it "refuses a link that is continued already, naming the next one (a double click); an archived link reached later still continues" do
      previous = make
      link = continue(previous.id)

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionContinue::Refused) { |e|
        expect(e).to have_attributes(reason: :continued, ids: [link.id])
        expect(e.message).to eq("#{previous.id[0, 8]} is continued already, by #{link.id[0, 8]}; " \
                                "continue that one (or last:#{previous.id[0, 8]})")
      }
      expect(Process).to have_received(:spawn).once

      Samagotchi::ArchiveStore.archive(link.id, state_dir: tmpdir)
      third = continue(link.id)
      expect(load(third.id).continues).to eq(link.id)
      expect(archived?(link.id)).to be(true)
    end

    it "refuses a live delegate on an older chi's worker (no reparent feature), naming it, and starts nothing" do
      previous = make
      old = make(prompt: "a", parent_id: previous.id, delegate: true)
      own(old.id)
      sidecar = Samagotchi::WorkerSidecar.new(port: 1, version: "0.46.1", features: %w[restart task_stop])
      allow(Samagotchi::WorkerLink).to receive(:resolve).and_call_original
      allow(Samagotchi::WorkerLink).to receive(:resolve).with(dir_of(old.id), unlink: false).and_return(live_link(sidecar))

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionContinue::Refused) { |e|
        expect(e).to have_attributes(reason: :open_children, ids: [old.id])
        expect(e.message).to include("#{old.id[0, 8]} (older chi worker 0.46.1; restart it)")
      }
      expect_nothing_started(previous)
      expect(Samagotchi::Session.parent_override(old.id, state_dir: tmpdir)).to be_nil
    end

    it "refuses what the archive would refuse before asking for the recap (a queued prompt)" do
      previous = make
      Samagotchi::SessionInbox.write_input(dir_of(previous.id), prompt: "queued", client_id: "cli:send")
      allow(described_class).to receive(:recap_before_archive)

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionManager::ArchiveRefused) { |e|
        expect(e.reason).to eq(:queued)
      }
      expect(described_class).not_to have_received(:recap_before_archive)
      expect_nothing_started(previous)
    end

    it "refuses while the previous link runs a turn (archive_session's rule)" do
      previous = make(status: Samagotchi::Session::STATUS_RUNNING)
      own(previous.id)

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionManager::ArchiveRefused) { |e|
        expect(e.reason).to eq(:busy)
      }
      expect_nothing_started(previous)
    end

    it "refuses when the previous link's folder is gone" do
      previous = make
      FileUtils.rm_rf(folder)

      expect { continue(previous.id) }.to raise_error(Samagotchi::SessionContinue::Refused, /folder .* is gone/)
      expect_nothing_started(previous)
    end

    it "refuses a model given for the new link whose host config.yml doesn't have, before the archive stops anything" do
      stub_hosts_config("main" => { "host" => "localhost", "port" => 8080 })
      previous = make
      allow(manager).to receive(:archive_session).and_call_original

      expect { continue(previous.id, model: "gone:org/model") }
        .to raise_error(Samagotchi::ModelProfile::UnknownHost, /unknown host 'gone'/)
      expect(manager).not_to have_received(:archive_session)
      expect_nothing_started(previous)
    end

    it "refuses a fallback when no default model is configured, before the archive stops anything" do
      stub_hosts_config("main" => { "host" => "localhost", "port" => 8080 })
      previous = make
      previous.model_name = "gone:org/model"
      previous.save(state_dir: tmpdir)
      allow(Samagotchi::ModelProfile).to receive(:default_model_name).and_return(nil)
      allow(manager).to receive(:archive_session).and_call_original

      expect { continue(previous.id) }.to raise_error(Samagotchi::ModelProfile::MissingModel)
      expect(manager).not_to have_received(:archive_session)
      expect_nothing_started(previous)
    end

    it "refuses an unknown session" do
      expect { continue("feedbeef") }.to raise_error(ArgumentError, "no session feedbeef")
      expect { continue("../etc") }.to raise_error(ArgumentError, "no session ../etc")
    end

    it "deletes a new link saved before its worker failed to spawn, so the chain stays continuable" do
      previous = make
      allow(Process).to receive(:spawn).and_raise(Errno::EAGAIN)

      expect { continue(previous.id) }.to raise_error(Errno::EAGAIN)
      expect(archived?(previous.id)).to be(false)
      expect(Samagotchi::Session.list(state_dir: tmpdir, include_archived: true).map(&:id)).to eq([previous.id])

      allow(Process).to receive(:spawn).and_return(12_345)
      expect(load(continue(previous.id).id).continues).to eq(previous.id)
    end

    it "puts what it archived back when the new link fails to start" do
      previous = make
      allow(manager).to receive(:spawn_session).and_raise(Samagotchi::ModelProfile::MissingModel, "no model")

      expect { continue(previous.id) }.to raise_error(Samagotchi::ModelProfile::MissingModel)
      expect(archived?(previous.id)).to be(false)
    end
  end

  describe "the new link's model" do
    it "runs on a model given for it, with the previous link's setup and the same note" do
      previous = make
      previous.thinking = :low
      previous.toolkit = Samagotchi::Toolkit.new(name: "coordinator")
      previous.settings = Samagotchi::SessionConfig::Settings.new(core: { "recap.enabled" => false }, bundles: { "cost-cap" => { "cap" => 3 } })
      previous.save(state_dir: tmpdir)

      link = continue(previous.id, model: "main:other-model")

      saved = load(link.id)
      expect(saved).to have_attributes(continues: previous.id, model_name: "main:other-model", model_typed: nil,
                                       thinking: :low, toolkit: Samagotchi::Toolkit.new(name: "coordinator"),
                                       settings: Samagotchi::SessionConfig::Settings.new(core: { "recap.enabled" => false }, bundles: { "cost-cap" => { "cap" => 3 } }))
      expect(link.model_warning).to be_nil
      expect(note_of(link.id)[:text]).to end_with("the previous link of its chain. It left no recap.\n\nIts last answer:\nok")
      expect(archived?(previous.id)).to be(true)
    end

    it "falls back to the default model with a warning when the previous link's host is gone" do
      stub_hosts_config("main" => { "host" => "localhost", "port" => 8080 })
      previous = make
      previous.model_name = "gone:org/model"
      previous.save(state_dir: tmpdir)

      link = continue(previous.id)

      expect(load(link.id).model_name).to eq(Samagotchi::HostConfig.model_ref("spec-model").ref)
      expect(link.model_warning).to match(%r{\Agone:org/model can't run \(unknown host 'gone' in model 'gone:org/model'.*\); started on spec-model\z})
      expect(archived?(previous.id)).to be(true)
    end

    it "falls back for a disabled host too, and keeps spawn's own warning after its own" do
      stub_hosts_config("main" => { "host" => "localhost", "port" => 8080 },
                        "box" => { "host" => "box.local", "port" => 8080, "enabled" => false })
      previous = make
      previous.model_name = "box:gemma"
      previous.save(state_dir: tmpdir)
      allow(Samagotchi::ModelProfile).to receive(:model_warning).and_return("spec-model isn't in main's list")

      link = continue(previous.id)

      expect(link.model_warning).to eq("box:gemma can't run (host 'box' is disabled (enabled: false in config.yml)); " \
                                       "started on spec-model; spec-model isn't in main's list")
    end

    it "picks a given model, else the inherited one, else the default with a warning (model_for)" do
      stub_hosts_config("main" => { "host" => "localhost", "port" => 8080 })
      previous = make
      expect(described_class.model_for(previous, "main:x")).to have_attributes(model: "main:x", warning: nil)
      expect(described_class.model_for(previous, " ")).to have_attributes(model: "main:gemma-small", warning: nil)
      previous.model_typed = "small"
      expect(described_class.model_for(previous, nil).model).to eq("small")
      previous.model_typed = nil
      previous.model_name = "gone:org/m"
      expect(described_class.model_for(previous, nil)).to have_attributes(model: "spec-model", warning: %r{\Agone:org/m can't run})
    end
  end

  it "locks per session: a continue of another chain doesn't wait for one still waiting on its recap" do
    slow = make
    other = make
    started = Queue.new
    release = Queue.new
    allow(described_class).to receive(:recap_before_archive).and_call_original
    allow(described_class).to receive(:recap_before_archive).with(slow.id, tmpdir, wait: 0) do
      started << true
      SpecWaiting.pop!(release, "the other chain's continue", timeout: 30)
    end
    waiting = Thread.new { continue(slow.id) }
    started.pop

    # The slow chain's continue still holds its lock: this one doesn't wait for it.
    link = continue(other.id)
    expect(load(link.id).continues).to eq(other.id)
    expect(waiting).to be_alive
  ensure
    release << true
    join!(waiting, "the slow chain's continue") if waiting
  end

  it "follows last:<id> to the chain's new end when another continue moved it meanwhile" do
    first = make
    second = continue(first.id)
    allow(Samagotchi::SessionChain).to receive(:resolve).and_call_original
    allow(Samagotchi::SessionChain).to receive(:resolve).with("last:#{first.id}", state_dir: tmpdir).and_return(first.id, second.id)

    third = continue("last:#{first.id}")
    expect(load(third.id).continues).to eq(second.id)
  end

  it "continues the chain's latest link for last:<any link>" do
    first = make
    second = continue(first.id)
    third = continue("last:#{first.id[0, 6]}")

    expect(load(third.id).continues).to eq(second.id)
    expect(Samagotchi::SessionChain.resolve("last:#{second.id}", state_dir: tmpdir)).to eq(third.id)
    expect(Samagotchi::SessionChain.resolve(third.id[0, 8], state_dir: tmpdir)).to eq(third.id)
  end

  # An idle new link holds only the carry note until its first message; it
  # is kept, not discarded as empty, with the note queued or absorbed.
  it "keeps an idle continuation that holds only the carry note" do
    link = continue(make.id)
    expect(manager.discardable?(link.id, default_model: "main:gemma-small", state_dir: tmpdir)).to be(false)

    note = note_of(link.id)
    saved = load(link.id)
    saved.messages = [{ role: "system", content: "prompt" }, Samagotchi::ContextNote.message(**note)]
    saved.save(state_dir: tmpdir)
    FileUtils.rm_rf(File.join(dir_of(link.id), Samagotchi::SessionInbox::NOTES_DIR))
    expect(manager.discardable?(link.id, default_model: "main:gemma-small", state_dir: tmpdir)).to be(false)
  end
end
