# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tempfile"
require "time"

module Samagotchi
  module Plugin
    # The base of the peer bundles' plugins (claude-peer, codex-peer;
    # docs/plugins.md): a live link between a chi session and another agent's
    # session the user works with. The peer pairs (its chi-peer skill,
    # scripts/pair): it attaches the `<peer>-inbox` context, whose hint says
    # where to send (a subclass's #check_hint!), and `<peer>-outbox`, where
    # its answers come back as pushes that wake chi.
    #
    # The `<peer>_send` tool sends a part of the work (a plan step, a diff, a
    # finding): a header, `chi <id> · <kind> · <title>`, then a short part
    # inline, or a long one's file under the bundle's data dir
    # (sessions/<id>/, removed with the session), named in the message
    # (`payload: <path>`). The tool is declared whether or not the peer is
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
    # A subclass (the bundle's Plugin) sets the strings, as constants:
    # INBOX, OUTBOX ("<peer>-inbox", "-outbox"), BUNDLE, NAME (the peer, as
    # the model and user call it: "Claude"), APP (its product: "Claude
    # Code"), COMMAND ("/claude"), TOOL, TOOL_DESCRIPTION, TOOL_PARAMS,
    # USAGE, STATUS_CARD, SKILL_CARD, CHECKED_ON and SCRIPTS_DIRS (beside the
    # bundle's own file), and the transport, as the hooks below that raise
    # NotImplementedError. Its constants are read as self.class::X: a bare
    # name here would find only this class's.
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
      PAYLOADS_PLACEHOLDER = "__CHI_PEER_PAYLOADS__"
      DIFF_LINES = 20
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

      def register(chi)
        peer = self.class
        chi.tool peer::TOOL, peer::TOOL_DESCRIPTION, params: peer::TOOL_PARAMS, label: "sent to #{peer::NAME}",
                                                     preview: ->(args) { "#{args["kind"]}: #{args["title"]}" } do |args, ctx|
          sent = deliver(ctx, kind: args["kind"].to_s, title: args["title"].to_s, text: args["text"].to_s)
          "#{sent}. #{follow_up(args["kind"].to_s)}"
        rescue SendError => e
          "Error: #{e.message}"
        end
        chi.command peer::COMMAND, "the paired #{peer::APP} session: status; validate|context <text>, last: send to " \
                                   "it; install-skill: install #{peer::NAME}'s chi-peer skill", anytime: true do |args, ctx|
          run_command(args.to_s.strip, ctx)
        end
        chi.annotation "Confirm with #{peer::NAME}", command: "#{peer::COMMAND} validate"
        # The outbox source is the peer's answers: its own wake budget and
        # line (context.peer_turns).
        chi.peer_source peer::OUTBOX, label: peer::NAME
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

      # Sends +text+ to the paired peer: the header, then the text inline or
      # a payload file's path. Records it as the last send.
      # @return [String] what was sent ("sent to Claude: validate · title")
      # @raise [SendError]
      def deliver(ctx, kind:, title:, text:)
        raise SendError, "kind must be one of #{KINDS.join(", ")}" unless KINDS.include?(kind)
        raise SendError, "nothing to send: the text is empty" if text.strip.empty?
        if text.length > MAX_CHARS
          raise SendError, "the text is #{text.length} chars, over #{MAX_CHARS}: send a part, not a session"
        end

        id = ctx.session_id or raise SendError, "this session has no id yet: send after its first turn"
        hint = peer_hint!(ctx)
        title = one_line(title.strip.empty? ? text.strip.lines.first : title)
        body, where = if text.length <= INLINE_CHARS
                        [text, "inline"]
                      else
                        path = write_payload(ctx, id, title, text)
                        ["payload: #{path} (#{text.lines.size} lines, #{text.length} chars)", path]
                      end
        post(hint, "chi #{id[0, 8]} · #{kind} · #{title}\n#{body}")
        record(ctx, id, kind: kind, title: title, chars: text.length, payload: where == "inline" ? nil : where)
        "sent to #{self.class::NAME}: #{kind} · #{title}#{" (the text in #{where})" unless where == "inline"}"
      end

      private

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
        "#{deliver(ctx, kind: kind, title: text_title(text), text: text)}; #{self.class::NAME}'s answer comes as the " \
          "#{self.class::OUTBOX} context"
      rescue SendError => e
        "#{self.class::COMMAND}: #{e.message}"
      end

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

        deliver(ctx, kind: "context", title: "chi's last answer: #{answer.strip.lines.first}", text: answer)
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
      # session not saved yet; a corrupt session file).
      def sources(ctx)
        ctx.context.list
      rescue ArgumentError, SystemCallError
        []
      end

      def role(message) = field(message, :role).to_s
      def kind(message) = field(message, :kind).to_s
      def field(hash, key) = hash.is_a?(Hash) ? hash[key] || hash[key.to_s] : nil

      # The paired peer's inbox hint: the inbox context's hint, checked by
      # the transport.
      # @raise [SendError]
      def peer_hint!(ctx)
        peer = self.class
        inbox = sources(ctx).find { |source| source[:name] == peer::INBOX }
        hint = inbox && inbox[:hint].to_s.strip
        if hint.nil? || hint.empty?
          raise SendError, "no #{peer::INBOX}: pair from #{peer::NAME} (install its skill with #{peer::COMMAND} " \
                           "install-skill, then tell #{peer::NAME} \"pair with chi #{ctx.session_id.to_s[0, 8]}\")"
        end
        check_hint!(hint)
        hint
      end

      # The status card; nil, so the command adds no text.
      def status(ctx)
        peer = self.class
        id = ctx.session_id
        sources = id ? sources(ctx) : []
        inbox, outbox = [peer::INBOX, peer::OUTBOX].map { |name| sources.find { |source| source[:name] == name } }
        hint = inbox && inbox[:hint].to_s.strip
        paired = !(hint.nil? || hint.empty?)
        lines = if paired
                  paired_lines(hint)
                else
                  ["**not paired.** In #{peer::APP}, install the chi-peer skill (Install skill below), then tell " \
                   "#{peer::NAME} \"pair with chi #{id.to_s[0, 8]}\"."]
                end
        lines << "last send: #{last_send_line(ctx, id)}" if id && last_send(ctx, id)
        lines << "last answer (#{peer::OUTBOX}): #{outbox_line(outbox)}" if outbox
        lines << "skill: **differs from this bundle's**: #{peer::COMMAND} install-skill (Replace), then pair again" if skill_differs?(ctx)
        lines << transport_line
        ctx.card(id: peer::STATUS_CARD, title: "#{peer::BUNDLE}: #{paired ? "paired" : "not paired"}",
                 body: lines.join("\n\n"), actions: [{ label: "Refresh", command: peer::COMMAND },
                                                     { label: "Install skill", command: "#{peer::COMMAND} install-skill" }])
        nil
      end

      def last_send(ctx, id)
        path = File.join(ctx.data_dir, "sessions", id, LAST_SEND)
        File.file?(path) ? JSON.parse(File.read(path)) : nil
      rescue JSON::ParserError, SystemCallError
        nil
      end

      def last_send_line(ctx, id)
        sent = last_send(ctx, id)
        where = sent["payload"] ? "in `#{sent["payload"]}`" : "inline"
        "#{ago(sent["at"])} · #{sent["kind"]} · #{sent["title"]} (#{sent["chars"]} chars, #{where})"
      end

      def outbox_line(outbox)
        return "none yet" unless outbox[:fetched_at]

        [outbox[:summary], ago(outbox[:fetched_at])].compact.join(" · ")
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

      def tilde(path)
        home = Dir.home
        path.start_with?("#{home}/") ? "~#{path.delete_prefix(home)}" : path
      end

      def follow_up(kind)
        case kind
        when "context" then "#{self.class::NAME} takes it in; it answers only if something in it is wrong."
        else "#{self.class::NAME}'s answer comes as an update of the #{self.class::OUTBOX} context; don't wait or poll."
        end
      end

      # sessions/<id>/<HHMMSS>-<slug>.md under the bundle's data dir, readable
      # by its owner only.
      def write_payload(ctx, id, title, text)
        dir = session_dir(ctx, id)
        base = "#{Time.now.strftime("%H%M%S")}-#{slug(title)}"
        path = File.join(dir, "#{base}.md")
        n = 1
        path = File.join(dir, "#{base}-#{n += 1}.md") while File.exist?(path)
        File.open(path, "w", 0o600) { |file| file.write(text) }
        path
      rescue SystemCallError => e
        raise SendError, "couldn't write the payload file: #{e.message}"
      end

      def session_dir(ctx, id)
        File.join(ctx.data_dir, "sessions", id).tap { |dir| FileUtils.mkdir_p(dir) }
      end

      def record(ctx, id, **send)
        entry = { at: Time.now.utc.iso8601, **send }
        @lock.synchronize { File.write(File.join(session_dir(ctx, id), LAST_SEND), JSON.generate(entry)) }
      rescue SystemCallError => e
        ctx.log.info(:last_send_not_saved, error: e.message)
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
