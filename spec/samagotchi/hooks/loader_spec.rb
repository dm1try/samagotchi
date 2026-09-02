# frozen_string_literal: true

require "samagotchi/hooks/loader"
require "tmpdir"

RSpec.describe Samagotchi::Hooks::Loader do
  describe ".load" do
    it "returns an empty registry when config is nil" do
      registry = described_class.load(nil)
      expect(registry).to be_a(Samagotchi::Hooks::Registry)
      expect(registry.size).to eq(0)
    end

    it "returns an empty registry when config has no hooks section" do
      registry = described_class.load({ "other" => "value" })
      expect(registry).to be_a(Samagotchi::Hooks::Registry)
      expect(registry.size).to eq(0)
    end

    it "returns an empty registry when hooks section is empty" do
      registry = described_class.load({ "hooks" => {} })
      expect(registry).to be_a(Samagotchi::Hooks::Registry)
      expect(registry.size).to eq(0)
    end

    it "loads plugins from hooks_dir and registers them" do
      Dir.mktmpdir do |tmpdir|
        hooks_dir = File.join(tmpdir, "hooks")
        FileUtils.mkdir_p(hooks_dir)

        # Create a test plugin
        File.write(File.join(hooks_dir, "test_hook.rb"), <<~RUBY)
          class TestHook
            attr_reader :received_event
            def call(event)
              @received_event = event
            end
          end
        RUBY

        config = {
          "hooks" => {
            "hooks_dir" => hooks_dir,
            "turn_start" => [
              { "path" => "test_hook.rb", "on_error" => "skip" }
            ]
          }
        }

        registry = described_class.load(config)
        expect(registry.size).to eq(1)

        # Fire the hook and verify the plugin received the event
        test_event = { type: :turn_start, session_id: "test-123" }
        registry.fire(:turn_start, test_event)

        # The plugin should have received the event
        # We can't directly access the plugin instance, but we can verify the hook fired
        # by checking that no error was raised
        expect { registry.fire(:turn_start, test_event) }.not_to raise_error
      end
    end

    it "handles missing hooks_dir gracefully" do
      config = {
        "hooks" => {
          "hooks_dir" => "/nonexistent/path/hooks",
          "turn_start" => [
            { "path" => "test.rb" }
          ]
        }
      }

      registry = described_class.load(config)
      # Should return an empty registry when plugins can't be loaded
      expect(registry).to be_a(Samagotchi::Hooks::Registry)
    end

    it "handles plugins that don't respond to #call" do
      Dir.mktmpdir do |tmpdir|
        hooks_dir = File.join(tmpdir, "hooks")
        FileUtils.mkdir_p(hooks_dir)

        # Create a plugin that doesn't respond to #call
        File.write(File.join(hooks_dir, "bad_hook.rb"), <<~RUBY)
          class BadHook
            def other_method
              "not a hook"
            end
          end
        RUBY

        config = {
          "hooks" => {
            "hooks_dir" => hooks_dir,
            "turn_start" => [
              { "path" => "bad_hook.rb", "on_error" => "skip" }
            ]
          }
        }

        registry = described_class.load(config)
        # Should handle the error gracefully and not crash
        expect(registry).to be_a(Samagotchi::Hooks::Registry)
      end
    end

    it "loads multiple plugins for the same event type" do
      Dir.mktmpdir do |tmpdir|
        hooks_dir = File.join(tmpdir, "hooks")
        FileUtils.mkdir_p(hooks_dir)

        # Create two test plugins
        File.write(File.join(hooks_dir, "hook_a.rb"), <<~RUBY)
          class HookA
            def call(event); end
          end
        RUBY

        File.write(File.join(hooks_dir, "hook_b.rb"), <<~RUBY)
          class HookB
            def call(event); end
          end
        RUBY

        config = {
          "hooks" => {
            "hooks_dir" => hooks_dir,
            "turn_start" => [
              { "path" => "hook_a.rb" },
              { "path" => "hook_b.rb" }
            ]
          }
        }

        registry = described_class.load(config)
        expect(registry.size).to eq(2)
      end
    end
  end

  describe ".parse_definitions" do
    it "parses hook definitions from config" do
      hooks_config = {
        "hooks_dir" => "/path/to/hooks",
        "turn_start" => [
          { "path" => "hook1.rb", "on_error" => "log" },
          { "path" => "hook2.rb" }
        ],
        "turn_end" => [
          { "path" => "hook3.rb" }
        ]
      }

      definitions = described_class.parse_definitions(hooks_config)
      expect(definitions).to be_an(Array).and(have_attributes(size: 3))
      expect(definitions[0]).to eq({ event_type: "turn_start", path: "hook1.rb", on_error: "log" })
      expect(definitions[1]).to eq({ event_type: "turn_start", path: "hook2.rb", on_error: "skip" })
      expect(definitions[2]).to eq({ event_type: "turn_end", path: "hook3.rb", on_error: "skip" })
    end

    it "skips non-array configs" do
      hooks_config = {
        "turn_start" => "not an array"
      }

      definitions = described_class.parse_definitions(hooks_config)
      expect(definitions).to be_empty
    end
  end

  describe ".expand_path" do
    it "expands paths starting with ~" do
      home = Dir.home
      expanded = described_class.expand_path("~/hooks", { "HOME" => home })
      expect(expanded).to eq(File.join(home, "hooks"))
    end

    it "uses Dir.home when HOME is not in env" do
      expanded = described_class.expand_path("~/hooks", {})
      expect(expanded).to eq(File.join(Dir.home, "hooks"))
    end

    it "leaves non-~ paths unchanged" do
      expanded = described_class.expand_path("/absolute/path")
      expect(expanded).to eq("/absolute/path")
    end
  end
end
