# The sample-plugin bundle (spec fixture, docs/plugins.md): one command,
# one tool and one hook; the command and the tool show cards.
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

    chi.tool "echo_args", "Echo the arguments back. A test tool from the sample-plugin bundle.",
             params: { text: { type: "string", description: "Any text to echo", required: true } },
             label: "echoing" do |args, ctx|
      echo = "echo: " + args.map { |key, value| "#{key}=#{value}" }.join(" ")
      ctx.card(title: "echo_args ran", body: echo)
      echo
    end

    chi.on(:after_turn) do |_event, ctx|
      File.open(File.join(ctx.data_dir, "turns.log"), "a") { |f| f.puts(ctx.session_id.to_s) }
    end
  end
end
