# frozen_string_literal: true

require "samagotchi/memory_bundle/file_state"
require "samagotchi/memory_bundle/file_actions"

module BundleStateCorpus
  # A case's FileState on its own starting tree (no command run), and what an
  # action predicts the corpus observed: the cells of expect/*.yml in the
  # Observer's words. file_state_spec and file_actions_spec read them.
  module States
    module_function

    # The commands' sources: demo's newer one, or the system bundle's at its
    # version (Remerge, restore).
    def source_for(sandbox, kase, flavor) = flavor == :system ? sandbox.same_source(kase) : sandbox.source(kase)

    # Yields the case's tree for +shape+ as the home, the record and its Provenance.
    def at_tree(sandbox, kase, shape, flavor)
      run = sandbox.run_copy(kase, shape, flavor == :system ? "restore" : "install")
      name = flavor == :system ? SYSTEM : NAME
      BundleStateCorpus.at_home(run) do
        target = File.join(BundleStateCorpus.memories_dir, kase.key)
        File.chmod(0o000, target) if kase.unreadable && File.exist?(target)
        begin
          provenance = Samagotchi::MemoryBundle::Provenance.new(name: name)
          yield provenance.record, provenance
        ensure
          File.chmod(0o644, target) if kase.unreadable && File.exist?(target)
        end
      end
    end

    # @param source [Boolean] the source universe, else the source-less one
    def state(sandbox, kase, shape, flavor: :demo, source: true)
      at_tree(sandbox, kase, shape, flavor) do |record, provenance|
        st = Samagotchi::MemoryBundle::FileState.of(
          kase.key, record: record, provenance: provenance, target_dir: BundleStateCorpus.memories_dir,
                    source_dir: source ? source_for(sandbox, kase, flavor) : nil,
                    claimants: ->(key) { Samagotchi::MemoryBundle::Provenance.claimants(key, scope: "system", except: provenance.name) }
        )
        outcome = decide_outcome(st, record, provenance, sandbox, kase, flavor) if source
        yield st, outcome if block_given?
        [st.kind, st.mark]
      end
    end

    # Merger::Upgrade's answer for the file, for a :decide cell.
    def decide_outcome(state, record, provenance, sandbox, kase, flavor)
      return nil unless record&.owns?(kase.key) && state.digests.incoming && state.digests.disk.is_a?(String)

      Samagotchi::MemoryBundle::Merger::Upgrade.new(provenance: provenance, target_dir: BundleStateCorpus.memories_dir,
                                                    source_dir: source_for(sandbox, kase, flavor)).outcome(kase.key)
    end

    # The summary's line for an action's word, per command.
    WORDS = { installed: "Installed", updated: "Updated", merged: "merged", kept: "Kept (local edits preserved)",
              kept_pruned: "Kept (local edits preserved)", up_to_date: "Up to date", kept_own: "Skipped",
              removed: "Removed (no longer in the bundle)", restored: "restored", settled: "settled" }.freeze

    # The cell +action+ predicts for the case, in the Observer's words.
    # @param merged [String, nil] a :merge's text
    def predict(kase, action, column, merged: nil)
      disk = kase.disk
      written = case action.do
                when :write_incoming, :restore then kase.incoming
                when :merge then merged
                when :move_to_trash then nil
                else disk
                end
      cell = { "do" => do_word(kase, action, written),
               "save_first" => action.do == :move_to_trash || (action.save_first && !disk.nil? && disk != written),
               "next_base" => text_word(kase, base_text(kase, action, written), written),
               "mark" => mark_word(kase, action.record) }
      cell["word"] = word_for(action, column)
      cell
    end

    def do_word(kase, action, written)
      case action.do
      when :write_incoming, :merge then if kase.disk == written then "kept"
                                        else written == kase.incoming ? "wrote_incoming" : "wrote_merge"
                                        end
      when :restore then "restored"
      when :move_to_trash then "moved"
      when :refuse then "refused"
      else kase.disk.nil? ? "none" : "kept"
      end
    end

    def base_text(kase, action, written)
      case action.next_base
      when :on_disk then written
      when :incoming then kase.incoming
      when :recorded then kase.base
      end
    end

    # The Observer's text_word: old (as before), disk, incoming, other.
    def text_word(kase, now, disk)
      return "none" if now.nil?
      return "old" if now == kase.base
      return "disk" if now == disk
      return "incoming" if now == kase.incoming

      "other"
    end

    def mark_word(kase, record)
      entry = kase.installed && kase.owned
      case record
      when :mark then kase.marked? ? "kept" : "set"
      when :hold_mark then if kase.marked?
                             "kept"
                           else
                             (entry ? "none" : "absent")
                           end
      when :drop then entry ? "dropped" : "absent"
      when :not_owned then "absent"
      else if entry
             kase.marked? ? "cleared" : "none"
           else
             "added"
           end
      end
    end

    def word_for(action, column)
      return "Moved to the trash" if column.start_with?("uninstall") && action.do == :move_to_trash

      WORDS[action.word]
    end
  end
end
