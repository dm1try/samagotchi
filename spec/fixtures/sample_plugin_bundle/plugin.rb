# The sample-plugin bundle (spec fixture, docs/plugins.md): one command,
# one tool and one hook.
class Plugin
  def initialize(settings)
    @greeting = settings.fetch("greeting", "hello")
  end

  def register(chi)
    chi.command "/hello", "greet, and say what the plugin sees" do |args, ctx|
      who = args.empty? ? "there" : args
      "#{@greeting}, #{who} (session #{ctx.session_id || "none"}, #{ctx.messages.size} messages)"
    end

    chi.tool "echo_args", "Echo the arguments back. A test tool from the sample-plugin bundle.",
             params: { text: { type: "string", description: "Any text to echo", required: true } },
             label: "echoing" do |args, _ctx|
      "echo: " + args.map { |key, value| "#{key}=#{value}" }.join(" ")
    end

    chi.on(:after_turn) do |_event, ctx|
      File.open(File.join(ctx.data_dir, "turns.log"), "a") { |f| f.puts(ctx.session_id.to_s) }
    end
  end
end
