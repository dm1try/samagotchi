# The sample-plugin bundle (spec fixture, docs/plugins.md): two commands,
# two tools and one hook; the commands and echo_args show cards.
class Plugin
  def initialize(settings)
    @greeting = settings.fetch("greeting", "hello")
    @hellos = 0
  end

  def register(chi)
    chi.command "/hello", "greet, and say what the plugin sees" do |args, ctx|
      who = args.empty? ? "there" : args
      @hellos += 1
      # One card, updated in place by each /hello (the same id).
      ctx.card(id: "hello", title: "#{@greeting}, #{who}",
               body: "This session has **#{ctx.messages.size}** messages.\n\n- said hello #{@hellos} time#{"s" unless @hellos == 1}\n- from the `sample-plugin` bundle",
               actions: [{ label: "Again", command: "/hello again" }])
      "#{@greeting}, #{who} (session #{ctx.session_id || "none"}, #{ctx.messages.size} messages)"
    end

    # Anytime: it runs at once, a turn running or not, on its own thread.
    chi.command "/hello-slow", "greet after 2 s, even mid-turn", anytime: true do |args, ctx|
      sleep 2
      ctx.card(title: "slow hello, #{args.empty? ? "there" : args}",
               body: "Ran beside the turn; it saw #{ctx.messages.size} messages.")
      nil
    end

    # args are typed by the params: a string shows as it is, anything else
    # with its class (times=3 (Integer)).
    chi.tool "echo_args", "Echo the arguments back. A test tool from the sample-plugin bundle.",
             params: { text: { type: "string", description: "Any text to echo", required: true },
                       times: { type: "integer", description: "How many times (optional)" },
                       loud: { type: "boolean", description: "Shout it (optional)" } },
             label: "echoing" do |args, ctx|
      echo = "echo: " + args.map { |key, value| value.is_a?(String) ? "#{key}=#{value}" : "#{key}=#{value.inspect} (#{value.class})" }.join(" ")
      ctx.card(title: "echo_args ran", body: echo)
      echo
    end

    # A nested schema: the native prompts declare it flat (the enum and the
    # object's fields in words), the chat path gets it whole.
    chi.tool "save_note", "Save a note to a file. A test tool from the sample-plugin bundle.",
             params: { path: { type: "string", description: "The file to write, relative to the working directory", required: true },
                       text: { type: "string", description: "The note", required: true },
                       format: { type: "string", enum: %w[plain markdown], description: "How the note is written" },
                       meta: { type: "object", description: "Extra fields for the note's header",
                               properties: { tags: { type: "array", items: { type: "string" } }, priority: { type: "integer" } },
                               additionalProperties: false } },
             label: "saving note",
             preview: ->(args) { "#{args["path"]} (#{args["text"].to_s.length} chars)" } do |args, ctx|
      path = File.expand_path(args["path"], ctx.cwd)
      meta = args["meta"].is_a?(Hash) ? args["meta"] : {}
      header = meta.map { |key, value| "#{key}: #{value.is_a?(Array) ? value.join(", ") : value}" }
      header.unshift("# note") if args["format"] == "markdown"
      File.write(path, (header + [args["text"].to_s]).join("\n") + "\n")
      "saved #{path}#{" (priority #{meta["priority"]}, #{meta["priority"].class})" if meta.key?("priority")}"
    end

    chi.on(:after_turn) do |_event, ctx|
      File.open(File.join(ctx.data_dir, "turns.log"), "a") { |f| f.puts(ctx.session_id.to_s) }
    end
  end
end
