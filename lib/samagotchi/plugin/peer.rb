# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "tempfile"
require "time"
require_relative "../config"
require_relative "../paths"
require_relative "../session"
require_relative "../peer_exchanges"
require_relative "../peer_mailbox"
require_relative "../peer_note"

module Samagotchi
  module Plugin
    # The base of the peer bundles' plugins (claude-peer, codex-peer;
    # docs/bundles.md, docs/peers.md): a live link between a chi session and
    # another agent's session the user works with. The peer pairs (its
    # chi-peer skill, scripts/pair: `chi peer pair NAME <id> --address …`):
    # the pairing's address says where to send (a subclass's #check_hint!).
    # Its answers come back as messages in the session's mailbox (`chi peer
    # say`), which the worker takes as the peer's notes (chi.peer NAME,
    # WorkerInbound#absorb_mail). A note too long to hold its text points at
    # the `<peer>_read` tool, declared here.
    #
    # The `<peer>_send` tool sends a part of the work (a plan step, a diff, a
    # finding): a header, `chi <id> · <kind> · <title>`, a `ref: <send id>`
    # line (.send_id: the peer's answer echoes it as `re`), then a short
    # part inline, or a long one's file under the bundle's data dir
    # (sessions/<id>/, removed with the session), named in the message
    # (`payload: <path>`). The tool's row carries the same id as a `peer`
    # ref (derived from the call's args and its run's tool id, so it is
    # there before the call runs: also on a send that then didn't happen;
    # an equal resend is a run of its own, so an id of its own). The tool is declared whether or not the peer is
    # paired, so pairing never changes the tools (no prompt rebuild); without
    # a paired peer it fails with how to pair.
    #
    # The `/<peer>` command (anytime) lets the user send without the model:
    # alone it is a status card; `validate|context <text>` sends the text as
    # it is, titled by its first line; `last` sends the model's last completed
    # answer as context (mid-turn, a worker's ctx.messages holds the running
    # turn's partial text, so the before_turn and after_turn hooks keep what
    # was completed); `install-skill` shows a card with the peer's chi-peer
    # skill's target and an Install action (`--yes`), the card being the
    # user's consent: the copy happens in-process, where no guardrail sees
    # it. The skill is the bundle's scripts/chi-peer-SKILL.md, with the
    # installed scripts/pair path and the payload folder written in.
    #
    # In the web, selecting text offers "Confirm with <peer>"
    # (chi.annotation): it fills the composer with `/<peer> validate` and the
    # quote. Such a text is titled by its first quoted line, not the quote's
    # `From your thinking:` label.
    #
    # A continue leaves the pairing with the previous link (its mailbox
    # stays there). The new link's quiet init task (#tell_moved) posts the
    # `moved` message to the address the previous link's pairing names
    # (ctx.peers.left_behind), once, so the peer pairs again with the new
    # id; its chi-peer skill knows how it paired.
    #
    # A subclass (the bundle's Plugin) sets the strings, as constants: PEER
    # (its mailbox name: "claude"), BUNDLE, NAME (the peer, as the model and
    # user call it: "Claude", PeerMailbox.label of PEER), APP (its product:
    # "Claude Code"), COMMAND ("/claude"), TOOL, READ_TOOL, TOOL_DESCRIPTION,
    # TOOL_PARAMS, USAGE, STATUS_CARD, SKILL_CARD, CHECKED_ON, SCRIPTS_DIRS
    # (beside the bundle's own file), LEGACY_INBOX and LEGACY_OUTBOX (the
    # context sources an older bundle paired through: the status card's
    # "paired the old way" line only; remove after the next release), and the transport, as the hooks
    # below that raise NotImplementedError. Its constants are read as
    # self.class::X: a bare name here would find only this class's.
    class Peer
      KINDS = %w[validate context question].freeze
      # A part up to this long goes inline: the peer reads it with no file
      # access.
      INLINE_CHARS = 4_000
      # A part longer than this is refused (a send is a part, not a session).
      MAX_CHARS = 200_000
      TITLE_CHARS = 80
      SLUG_CHARS = 40
      LAST_SEND = "last-send.json"
      SKILL_FILE = "chi-peer-SKILL.md"
      PAIR_PLACEHOLDER = "__CHI_PEER_PAIR__"
      # scripts/pair-remote's path (claude-peer's skill: the SSH pairing).
      PAIR_REMOTE_PLACEHOLDER = "__CHI_PEER_PAIR_REMOTE__"
      PAYLOADS_PLACEHOLDER = "__CHI_PEER_PAYLOADS__"
      DIFF_LINES = 20
      # Under the session's data dir: the moved message went (or was tried).
      MOVED_MARKER = "moved-posted"
      # The <peer>_read tool's page, at most (its output's cap, as context_read's).
      READ_DEFAULT_CHARS = 10_000
      READ_MIN_CHARS = 2_000
      # The label line a web quote starts with (annotations.js sourceLabel).
      QUOTE_LABEL = /\AFrom (?:your thinking|your earlier step|the .+ call|my earlier message):\z/

      # A send that didn't happen; the message says why, for the model or the user.
      class SendError < StandardError; end

      def initialize(_settings = {})
        @lock = Mutex.new
        # The running turn's history before it (nil between turns), and the
        # last completed answer this process saw.
        @before_turn = nil
        @last_answer = nil
      end

      # A send's id, from what the caller gave (before the title is cut):
      # `s-` and 6 hex of SHA-256 over +kind+, +title+, +text+ and +salt+,
      # the send's own: the tool's run id (its row's ref is computed before
      # the call runs, so from the args and the run, ctx.tool_id), a random
      # one for a /<peer> command's. A nil +salt+ is the id over the three
      # alone, what a send before 0.181.0 got (and a run with no id): its
      # log and answers still name it. The peer's answer names it (`re`).
      def self.send_id(kind, title, text, salt = nil)
        parts = salt.nil? ? [kind, title, text] : [kind, title, text, salt.to_s]
        "s-#{Digest::SHA256.hexdigest(parts.join("\0"))[0, 6]}"
      end

      def register(chi)
        peer = self.class
        unless peer.const_defined?(:PEER) && peer.const_defined?(:READ_TOOL)
          raise ArgumentError, "chi.peer_source is gone: upgrade this bundle " \
                              "(chi bundle install #{peer::BUNDLE} --force)"
        end
        # Two args: the run's tool id salts the send id, the same one the
        # block's deliver gets (ctx.tool_id).
        refs = lambda do |args, tool_id = nil|
          id = Peer.send_id(args["kind"].to_s, args["title"].to_s, args["text"].to_s, tool_id)
          [{ kind: "peer", target: { id: id }, label: "#{peer::NAME} · #{args["kind"].to_s[0, 40]}" }]
        end
        chi.tool peer::TOOL, peer::TOOL_DESCRIPTION, params: peer::TOOL_PARAMS, label: "sent to #{peer::NAME}",
                                                     preview: ->(args) { "#{args["kind"]}: #{args["title"]}" },
                                                     refs: refs do |args, ctx|
          sent = deliver(ctx, kind: args["kind"].to_s, title: args["title"].to_s, text: args["text"].to_s,
                              salt: ctx.tool_id)
          "#{sent}. #{follow_up(args["kind"].to_s)}"
        rescue SendError => e
          "Error: #{e.message}"
        end
        chi.command peer::COMMAND, "the paired #{peer::APP} session: status; validate|context <text>, last: send to " \
                                   "it; install-skill: install #{peer::NAME}'s chi-peer skill", anytime: true do |args, ctx|
          run_command(args.to_s.strip, ctx)
        end
        chi.tool peer::READ_TOOL, read_description, params: READ_PARAMS, label: "read #{peer::NAME}'s message",
                                                     preview: ->(args) { "##{args["serial"]}" } do |args, ctx|
          read_message(ctx, args)
        end
        chi.annotation "Confirm with #{peer::NAME}", command: "#{peer::COMMAND} validate"
        chi.init("Telling #{peer::NAME} the session moved", quiet: true) { |ctx| tell_moved(ctx) }
        # Its messages in the mailbox are this peer's: its notes, its wake
        # budget and lines (peer.turns).
        chi.peer peer::PEER
        chi.on(:before_turn) do |event|
          @lock.synchronize { @before_turn = Array(event[:messages]) }
        end
        chi.on(:after_turn) do |event|
          answer = completed_answer(event[:messages]) if event[:status].to_s == "completed"
          @lock.synchronize do
            @before_turn = nil
            @last_answer = answer if answer
          end
        end
      end

      # Sends +text+ to the paired peer: the header, the `ref:` line
      # (.send_id of the args as given and +salt+: the tool row's, so the
      # row and the line name the same send), then the text inline or a
      # payload file's path. Records it as the last send, with its id.
      # @return [String] what was sent ("sent to Claude: validate · title")
      # @raise [SendError]
      def deliver(ctx, kind:, title:, text:, by: "model", salt: nil)
        raise SendError, "kind must be one of #{KINDS.join(", ")}" unless KINDS.include?(kind)
        raise SendError, "nothing to send: the text is empty" if text.strip.empty?
        if text.length > MAX_CHARS
          raise SendError, "the text is #{text.length} chars, over #{MAX_CHARS}: send a part, not a session"
        end

        send_id = Peer.send_id(kind, title, text, salt)
        id = ctx.session_id or raise SendError, "this session has no id yet: send after its first turn"
        hint = peer_hint!(ctx)
        title = one_line(title.strip.empty? ? text.strip.lines.first : title)
        body, where = if text.length <= INLINE_CHARS
                        [text, "inline"]
                      else
                        path = write_payload(ctx, title, text)
                        ["payload: #{path} (#{text.lines.size} lines, #{text.length} chars)", path]
                      end
        begin
          post(hint, "chi #{id[0, 8]} · #{kind} · #{title}\nref: #{send_id}\n#{body}")
        rescue SendError => e
          exchange(ctx, t: "send_failed", id: send_id, kind: kind, title: title, error: e.message)
          raise
        end
        exchange(ctx, t: "sent", id: send_id, kind: kind, title: title, chars: text.length, by: by)
        record(ctx, id: send_id, kind: kind, title: title, chars: text.length, payload: where == "inline" ? nil : where)
        "sent to #{self.class::NAME}: #{kind} · #{title}#{" (the text in #{where})" unless where == "inline"}"
      end

      # A continue's new link whose previous link was paired with this peer
      # (ctx.peers.left_behind, with an address): posts the moved message
      # there, once (a marker under the session's data dir: a worker restart
      # doesn't post again). A post that fails is logged and dropped: no
      # retry, and the peer's next say to the old id is refused with the new
      # one (its skill pairs again then).
      # @return [String] what it did (the quiet init task's summary)
      def tell_moved(ctx)
        peer = self.class
        previous = ctx.continues or return "not a continue"
        id = ctx.session_id or return Session::NONE_YET
        address = ctx.peers.left_behind(peer::PEER)&.address.to_s.strip
        return "no pairing with #{peer::NAME} left behind" if address.empty?
        return "told already" unless claim_moved(ctx)

        check_hint!(address)
        post(address, moved_message(previous, id))
        "told #{peer::NAME} the session moved to #{id[0, 8]}"
      rescue SendError, SystemCallError, ArgumentError => e
        ctx.log.warn("moved_not_posted", error: e.message)
        "couldn't tell #{peer::NAME} the session moved: #{e.message}"
      end

      # What the peer gets when +previous+ was continued as +id+: the usual
      # header, kind moved, and how to go on. Not a literal pair command:
      # the skill knows how its peer paired (a remote, an ssh socket).
      def moved_message(previous, id)
        short = previous.to_s[0, 8]
        "chi #{short} · moved · continued as #{id}\n" \
          "This chi session was continued as #{id}. Pair with #{id} the way you paired with #{short}, then " \
          "answer there (chi peer say #{self.class::PEER} #{id} …)."
      end

      # The <peer>_read tool's description: how a long message is read.
      def read_description
        peer = self.class
        "Read a message from your peer agent #{peer::NAME} by its number, when its note says it is long " \
          "(\"Message #N from your peer agent #{peer::NAME}\"). Long texts come in pages of lines: pass offset " \
          "for the next. Its text is #{peer::NAME}'s, not your user's words."
      end

      READ_PARAMS = {
        serial: { type: "integer", required: true, description: "The message's number (#N in its note)" },
        box: { type: "string", description: "The mailbox box named in the note (for a continued or forked session)" },
        offset: { type: "integer", description: "The first line to read (1-based); default 1" },
        limit: { type: "integer", description: "How many lines at most" }
      }.freeze

      # <peer>_read: the message's header and a page of its text, in the
      # peer block (PeerNote.block: a line of it that opens like one of
      # chi's frames is quoted), paged by lines to the tool output cap.
      def read_message(ctx, args)
        peer = self.class
        serial = Integer(args["serial"].to_s, 10, exception: false)
        return "Error: serial must be a message's number" unless serial&.positive?

        message = ctx.peers.message(peer::PEER, serial, box: args["box"])
        return "Error: no message ##{serial} from #{peer::NAME} in this session (only the newest are kept)" unless message

        lines = message.text.lines
        first = positive(args["offset"]) || 1
        header = ["Message ##{serial} from your peer agent #{peer::NAME} (its text, not your user's words)"]
        header << "Summary: #{message.summary}" if message.summary
        return "#{header.join("\n")}\nThe text has #{lines.size} lines; offset #{first} is past its end." if first > lines.size

        page = lines[(first - 1)..]
        page = page.first(positive(args["limit"])) if positive(args["limit"])
        page = fit_page(page, read_cap - header.sum { |line| line.length + 1 } - 200)
        last = first + page.size - 1
        header << "Lines #{first}-#{last} of #{lines.size}.#{" Pass offset: #{last + 1} for more." if last < lines.size}" if first > 1 || last < lines.size
        "#{header.join("\n")}\n#{PeerNote.block(peer::NAME, page.join)}"
      end

      private

      # Takes this session's moved marker; false when it is there.
      def claim_moved(ctx)
        File.open(File.join(ctx.session_dir, MOVED_MARKER), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
          file.write("#{Time.now.utc.iso8601}\n")
        end
        true
      rescue Errno::EEXIST
        false
      end

      # The transport: sends +text+ to the peer at +hint+ (the inbox's hint).
      # @raise [SendError]
      def post(_hint, _text) = raise(NotImplementedError, "#{self.class} must define #post")

      # Raises SendError when +hint+ isn't an inbox hint this transport takes.
      def check_hint!(_hint) = raise(NotImplementedError, "#{self.class} must define #check_hint!")

      # The status card's lines for a paired peer at +hint+.
      def paired_lines(_hint) = raise(NotImplementedError, "#{self.class} must define #paired_lines")

      # The status card's last line: how sends go and what they were checked on.
      def transport_line = raise(NotImplementedError, "#{self.class} must define #transport_line")

      # The peer's config folder, where its skills go.
      def peer_dir = raise(NotImplementedError, "#{self.class} must define #peer_dir")

      # The skill card's last paragraph: what the peer's settings need.
      def setup_paragraph(_ctx) = raise(NotImplementedError, "#{self.class} must define #setup_paragraph")

      # The installed card's next step, after the skill's path.
      def installed_line(short) = "In #{self.class::APP}, say \"pair with chi #{short}\"."

      # More placeholders the installed skill fills in: {placeholder => text}.
      def skill_substitutions(_ctx) = {}

      # What the transport needs once the skill is written (codex-peer: its
      # sandbox's writable root).
      def skill_installed(_ctx) = nil

      def run_command(args, ctx)
        verb = args.split(/\s+/, 2).first
        # The rest as typed: a pasted selection keeps its lines.
        rest = args.sub(/\A\S+\s*/, "")
        case verb
        when nil then status(ctx)
        when "validate", "context" then rest.strip.empty? ? self.class::USAGE : send_text(ctx, verb, rest)
        when "last" then rest.empty? ? send_last(ctx) : self.class::USAGE
        when "install-skill" then install_skill(ctx, yes: rest == "--yes")
        else self.class::USAGE
        end
      end

      def send_text(ctx, kind, text)
        "#{deliver(ctx, kind: kind, title: text_title(text), text: text, by: "user", salt: command_salt)}; #{self.class::NAME}'s answer comes as a " \
          "message with its text"
      rescue SendError => e
        "#{self.class::COMMAND}: #{e.message}"
      end

      # A /<peer> command send's salt (.send_id): it has no tool row to agree
      # with, so a random one keeps an equal resend's id its own.
      def command_salt = SecureRandom.hex(4)

      # A typed text's title: its first line, past a web quote's label line
      # (`From your thinking:`) and the `> ` of a quoted line.
      def text_title(text)
        lines = text.strip.lines.map(&:strip).reject { |line| line.match?(QUOTE_LABEL) }
        lines.map { |line| line.sub(/\A>\s*/, "") }.find { |line| !line.empty? }.to_s
      end

      def send_last(ctx)
        answer, before = @lock.synchronize { [@last_answer, @before_turn] }
        answer ||= completed_answer(before || ctx.messages)
        command = self.class::COMMAND
        return "#{command} last: no completed answer to send yet (the last turn has none); #{command} context <text> sends a text" unless answer

        deliver(ctx, kind: "context", title: "chi's last answer: #{answer.strip.lines.first}", text: answer, by: "user",
                     salt: command_salt)
      rescue SendError => e
        "#{command}: #{e.message}"
      end

      # The answer a completed turn left: the history's last message when it
      # is the model's (a cancelled, failed or empty turn ends in a turn note),
      # after any notes that joined between turns; its thinking left out.
      def completed_answer(messages)
        last = Array(messages).reverse.find { |message| !(role(message) == "system" && kind(message) != "turn_note") }
        return nil unless last && role(last) == "model" && !field(last, :interrupted) && !field(last, :tool_calls)

        text = field(last, :content)
        text = text.filter_map { |part| field(part, :text) if part.is_a?(Hash) }.join("\n") if text.is_a?(Array)
        text = text.to_s.gsub(%r{<think>.*?</think>}m, "").strip
        text.empty? ? nil : text
      end

      # The session's attached sources; none when they can't be read (a new
      # session not saved yet; a corrupt session file). Only the status
      # card's "paired the old way" line reads them (LEGACY_INBOX, LEGACY_OUTBOX).
      def sources(ctx)
        ctx.context.list
      rescue ArgumentError, SystemCallError
        []
      end

      # Whether an older bundle's pairing (its LEGACY_INBOX or LEGACY_OUTBOX
      # context source) is attached.
      def paired_the_old_way?(ctx)
        old = [self.class::LEGACY_INBOX, self.class::LEGACY_OUTBOX]
        sources(ctx).any? { |source| old.include?(source[:name]) }
      end

      def positive(value)
        number = Integer(value.to_s, 10, exception: false)
        number if number&.positive?
      end

      # The tool output cap a <peer>_read page fits (max_tool_output_chars).
      def read_cap
        value = Config.get("max_tool_output_chars").to_i
        [value.positive? ? value : READ_DEFAULT_CHARS, READ_MIN_CHARS].max
      end

      # The lines of +page+ that fit in +room+ characters, at least one
      # (cut to the room when one line is over it).
      def fit_page(page, room)
        room = [room, 200].max
        kept = []
        used = 0
        page.each do |line|
          break if used + line.length > room && kept.any?

          kept << (line.length > room ? line[0, room] : line)
          used += line.length
        end
        kept
      end

      def role(message) = field(message, :role).to_s
      def kind(message) = field(message, :kind).to_s
      def field(hash, key) = hash.is_a?(Hash) ? hash[key] || hash[key.to_s] : nil

      # Where the paired peer takes sends: the pairing's address
      # (ctx.peers.link), checked by the transport.
      # @raise [SendError]
      def peer_hint!(ctx)
        peer = self.class
        link = ctx.peers.link(peer::PEER)
        unless link
          raise SendError, "#{peer::NAME} isn't paired: pair from #{peer::NAME} (install its skill with " \
                           "#{peer::COMMAND} install-skill, then tell #{peer::NAME} \"pair with chi " \
                           "#{ctx.session_id.to_s[0, 8]}\")"
        end
        address = link.address.to_s.strip
        raise SendError, answers_only_line if address.empty?

        check_hint!(address)
        address
      end

      # A pairing with no address: the peer can answer, chi can't send.
      def answers_only_line
        peer = self.class
        "#{peer::NAME} paired for answers only (it runs where chi can't reach it): chi can't send to it; pair " \
          "again from #{peer::NAME} with an address chi can reach"
      end

      # The status card; nil, so the command adds no text.
      def status(ctx)
        peer = self.class
        id = ctx.session_id
        link = id && ctx.peers.link(peer::PEER)
        address = link&.address.to_s.strip
        lines = if link && !address.empty?
                  paired_lines(address)
                elsif link
                  ["**paired** for answers only: #{peer::NAME} can answer here, chi can't send to it (it paired " \
                   "with no address chi can reach)"]
                elsif id && paired_the_old_way?(ctx)
                  ["**paired the old way: pair again** (install the skill first: Install skill below, then tell " \
                   "#{peer::NAME} \"pair with chi #{id[0, 8]}\")."]
                else
                  ["**not paired.** In #{peer::APP}, install the chi-peer skill (Install skill below), then tell " \
                   "#{peer::NAME} \"pair with chi #{id.to_s[0, 8]}\"."]
                end
        paired = !link.nil?
        lines << "last send: #{last_send_line(ctx)}" if id && last_send(ctx)
        if link
          last = ctx.peers.last_message(peer::PEER)
          lines << "last message from #{peer::NAME} (its text in the conversation): #{message_line(last)}"
        end
        lines << "skill: **differs from this bundle's**: #{peer::COMMAND} install-skill (Replace), then pair again" if skill_differs?(ctx)
        lines << transport_line
        ctx.card(id: peer::STATUS_CARD, title: "#{peer::BUNDLE}: #{paired ? "paired" : "not paired"}",
                 body: lines.join("\n\n"), actions: [{ label: "Refresh", command: peer::COMMAND },
                                                     { label: "Install skill", command: "#{peer::COMMAND} install-skill" }])
        nil
      end

      def last_send(ctx)
        path = File.join(ctx.session_dir(create: false), LAST_SEND)
        File.file?(path) ? JSON.parse(File.read(path)) : nil
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def last_send_line(ctx)
        sent = last_send(ctx)
        where = sent["payload"] ? "in `#{sent["payload"]}`" : "inline"
        "#{ago(sent["at"])} · #{sent["kind"]} · #{sent["title"]} (#{sent["chars"]} chars, #{where})"
      end

      def message_line(message)
        return "none yet" unless message

        ["##{message.serial}", message.summary, ago(message.at)].compact.join(" · ")
      end

      def ago(stamp)
        seconds = (Time.now - Time.iso8601(stamp.to_s)).to_i
        if seconds < 60 then "just now"
        elsif seconds < 3600 then "#{seconds / 60} min ago"
        elsif seconds < 86_400 then "#{seconds / 3600} h ago"
        else Time.iso8601(stamp).localtime.strftime("%Y-%m-%d %H:%M")
        end
      rescue ArgumentError
        stamp.to_s
      end

      # /<peer> install-skill [--yes]
      def install_skill(ctx, yes:)
        peer = self.class
        target, text = skill_target_and_text(ctx)
        return "#{peer::COMMAND} install-skill: this bundle has no scripts/#{SKILL_FILE}; reinstall it (chi bundle install #{peer::BUNDLE} --force)" unless text

        yes ? write_skill(ctx, target, text) : skill_card(ctx, target, text)
      end

      # Where install-skill writes the peer's skill and what it writes:
      # [target, text]; the text nil when the bundle has no skill file.
      def skill_target_and_text(ctx)
        target = File.join(peer_dir, "skills", "chi-peer", "SKILL.md")
        source = self.class::SCRIPTS_DIRS.map { |dir| File.join(dir, SKILL_FILE) }.find { |path| File.file?(path) }
        return [target, nil] unless source

        substitutions = { PAIR_PLACEHOLDER => File.join(File.dirname(source), "pair"),
                          PAIR_REMOTE_PLACEHOLDER => File.join(File.dirname(source), "pair-remote"),
                          PAYLOADS_PLACEHOLDER => tilde(ctx.data_dir) }.merge(skill_substitutions(ctx))
        [target, substitutions.reduce(File.read(source)) { |skill, (placeholder, value)| skill.gsub(placeholder, value) }]
      end

      # Whether the peer's installed skill isn't what install-skill would
      # write (an older bundle's, or the user's edit): the status card says
      # so. Not installed, or unreadable: no.
      def skill_differs?(ctx)
        target, text = skill_target_and_text(ctx)
        text && File.file?(target) && File.read(target) != text
      rescue SystemCallError
        false
      end

      def skill_card(ctx, target, text)
        peer = self.class
        current = File.file?(target) ? File.read(target) : nil
        state = if current.nil? then "Not installed yet."
                elsif current == text then "Installed and up to date."
                else "Installed, and different from this bundle's (Replace overwrites it):\n\n```diff\n#{diff(target, text)}\n```"
                end
        body = ["#{peer::APP}'s side: it pairs (`pair with chi <id>`), answers validates and replies into chi.",
                "target: `#{target}`", state, setup_paragraph(ctx)]
        actions = if current == text
                    []
                  else
                    [{ label: current ? "Replace" : "Install", command: "#{peer::COMMAND} install-skill --yes" }]
                  end
        ctx.card(id: peer::SKILL_CARD, title: "#{peer::NAME}'s chi-peer skill", body: body.join("\n\n"), actions: actions)
        nil
      end

      def write_skill(ctx, target, text)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, text)
        skill_installed(ctx)
        ctx.card(id: self.class::SKILL_CARD, title: "#{self.class::NAME}'s chi-peer skill",
                 body: "Installed `#{target}`. #{installed_line(ctx.session_id.to_s[0, 8])}")
        nil
      rescue SystemCallError => e
        "#{self.class::COMMAND} install-skill: couldn't write #{target}: #{e.message}"
      end

      # The first lines of `diff -u installed new`.
      def diff(target, text)
        Tempfile.create(["chi-peer", ".md"]) do |file|
          file.write(text)
          file.flush
          out, = Open3.capture2("diff", "-u", "--label", "installed", "--label", "this bundle's", target, file.path)
          lines = out.lines
          lines = lines.first(DIFF_LINES) + ["… #{lines.size - DIFF_LINES} more lines\n"] if lines.size > DIFF_LINES
          lines.join.chomp
        end
      rescue SystemCallError
        "(diff isn't there to show how)"
      end

      def tilde(path) = Paths.tilde(path)

      def follow_up(kind)
        case kind
        when "context" then "#{self.class::NAME} takes it in; it answers only if something in it is wrong."
        else "#{self.class::NAME}'s answer comes as a message with its text; don't wait or poll."
        end
      end

      # <HHMMSS>-<slug>.md in ctx.session_dir, readable by its owner only.
      def write_payload(ctx, title, text)
        dir = ctx.session_dir
        base = "#{Time.now.strftime("%H%M%S")}-#{slug(title)}"
        path = File.join(dir, "#{base}.md")
        n = 1
        path = File.join(dir, "#{base}-#{n += 1}.md") while File.exist?(path)
        File.open(path, "w", 0o600) { |file| file.write(text) }
        path
      rescue SystemCallError => e
        raise SendError, "couldn't write the payload file: #{e.message}"
      end

      def record(ctx, **send)
        entry = { at: Time.now.utc.iso8601, **send }
        @lock.synchronize { File.write(File.join(ctx.session_dir, LAST_SEND), JSON.generate(entry)) }
      rescue SystemCallError => e
        ctx.log.info(:last_send_not_saved, error: e.message)
      end

      def exchange(ctx, **entry)
        PeerExchanges.append(ctx.session_id, { peer: self.class::PEER, **entry }, state_dir: ctx.session_state_dir)
      rescue SystemCallError, IOError, JSON::GeneratorError => e
        ctx.log.warn("peer_exchange_not_saved", error: e.message)
      end

      def slug(title)
        slug = title.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, SLUG_CHARS].delete_suffix("-")
        slug.empty? ? "part" : slug
      end

      def one_line(text)
        line = text.to_s.gsub(/\s+/, " ").strip
        line.length > TITLE_CHARS ? "#{line[0, TITLE_CHARS - 1]}…" : line
      end
    end
  end
end
