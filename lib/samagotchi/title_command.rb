# frozen_string_literal: true

module Samagotchi
  # /title, the session's own name (Session#title): with no argument, the
  # title and what shows without one; `/title TEXT` names the session
  # (whitespace collapsed, cut at 80 characters as a preview is);
  # `/title --clear` drops it, and the lists show the first message again.
  # Anyone who may send the session a command may name it (a parent agent
  # its delegates too). It doesn't save: its host saves a changed result at
  # once (Worker, the REPL). It runs mid-turn as well (anytime): the
  # worker's save takes the session's lock and writes a running turn's
  # checkpoint, as a turn's own saves do.
  class TitleCommand
    NAME = "/title"
    CLEAR = "--clear"
    USAGE = "usage: #{NAME} [TEXT|#{CLEAR}]".freeze
    # As long as a preview (Session.preview_of) may be.
    LIMIT = 80

    # @param engine [Engine] #session
    def initialize(engine:)
      @engine = engine
    end

    # @param args [String] what follows /title
    # @return [Array(String, Boolean, Symbol)] the reply, whether the
    #   title changed, and :ok or :error
    def run(args)
      session = @engine.session or return ["no session yet", false, :error]
      text = args.to_s.gsub(/\s+/, " ").strip
      return [listing(session), false, :ok] if text.empty?
      # "--clear and more" is a slip, not a title.
      return [USAGE, false, :error] if text.start_with?("#{CLEAR} ")

      title = if text == CLEAR then nil
              elsif text.length > LIMIT then "#{text[0, LIMIT]}…"
              else text
              end
      return ["#{listing(session)}\n(no change)", false, :ok] if title == session.title

      session.title = title
      # The command itself as the session's first line (chi send --new
      # "/title X", a web first message) became its preview: it goes, and
      # the host's save derives the preview from the first user message again.
      session.first_preview = "" if session.first_preview.to_s.start_with?(NAME)
      [listing(session), true, :ok]
    end

    private

    # "title: Coordinator", "title: none (shows the auto title: Parser tab
    # handling)" (the recap's, RecapTitle), or "title: none (shows the
    # first message: hey chi …)"
    def listing(session)
      return "title: #{session.title}" if session.title

      auto = @engine.recap&.state&.dig(:title)
      return "title: none (shows the auto title: #{auto})" if auto

      preview = session.first_preview.to_s
      "title: none (shows #{preview.empty? ? "the first message" : "the first message: #{preview}"})"
    end
  end
end
