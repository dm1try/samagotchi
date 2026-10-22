# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "digest"
require "spec_helper"
require "samagotchi/session_config"

# --set KEY=VALUE (a session-settable core key, typed by its Config entry)
# or BUNDLE.KEY=VALUE: a bundle's values parsed as YAML scalars, then
# checked against the installed bundles and the keys their manifests offer
# (session_settings:).
RSpec.describe Samagotchi::SessionConfig do
  let(:offered) { { "cost-cap" => ["cap"], "loop-guard" => [] } }

  def parse(*args) = described_class.parse(args, bundles: offered)
  def bundles(*args) = parse(*args).bundles

  describe ".parse" do
    it "reads BUNDLE.KEY=VALUE, typing the value, by bundle" do
      expect(bundles("cost-cap.cap=3", "cost-cap.note='5'", "other.on=true", "other.ratio=2.5", "other.name=fast lane"))
        .to eq("cost-cap" => { "cap" => 3, "note" => "'5'" },
               "other" => { "on" => true, "ratio" => 2.5, "name" => "fast lane" })
    end

    it "lets a later --set of the same key win" do
      expect(bundles("cost-cap.cap=3", "cost-cap.cap=0.5")).to eq("cost-cap" => { "cap" => 0.5 })
    end

    it "keeps a = in the value" do
      expect(bundles("a.expr=x=1")).to eq("a" => { "expr" => "x=1" })
    end

    it "returns a Settings, its parts frozen" do
      settings = parse("cost-cap.cap=3", "recap.enabled=off")
      expect(settings).to be_a(described_class::Settings)
      expect(settings.bundles).to be_frozen
      expect(settings.bundles["cost-cap"]).to be_frozen
      expect(settings.core).to be_frozen.and eq("recap.enabled" => false)
    end

    it "refuses the shapes that aren't KEY=VALUE or BUNDLE.KEY=VALUE" do
      {
        "foo" => "--set takes KEY=VALUE or BUNDLE.KEY=VALUE, not foo",
        ".k=v" => "--set takes KEY=VALUE or BUNDLE.KEY=VALUE, not .k=v",
        "b.=v" => "--set takes KEY=VALUE or BUNDLE.KEY=VALUE, not b.=v",
        "a.b.c=1" => "--set a.b.c=1: one key under the bundle (BUNDLE.KEY), no nested path",
        "a b.c=1" => "--set takes KEY=VALUE or BUNDLE.KEY=VALUE, not a b.c=1",
        "a.b=" => "--set a.b=: give a value",
        "recap.enabled= " => "--set recap.enabled= : give a value"
      }.each do |arg, message|
        expect { parse(arg) }.to raise_error(described_class::Error, message), arg
      end
    end
  end

  describe "core keys" do
    it "takes a session-settable core key first, typed by its Config entry (bool words, 1/0; N or N-M as text)" do
      { "true" => true, "On" => true, "1" => true, "no" => false, "OFF" => false, "0" => false }.each do |raw, value|
        expect(parse("recap.enabled=#{raw}").core).to eq("recap.enabled" => value), raw
      end
      expect(parse("recap.sentences=3").core).to eq("recap.sentences" => "3")
      expect(parse("recap.sentences=2-5", "recap.enabled=false", "cost-cap.cap=3"))
        .to have_attributes(core: { "recap.sentences" => "2-5", "recap.enabled" => false }, bundles: { "cost-cap" => { "cap" => 3 } })
    end

    it "refuses a value its entry doesn't take, one wording per condition" do
      {
        "recap.enabled=maybe" => '--set recap.enabled: recap.enabled takes true or false, not "maybe"',
        "recap.sentences=11" => '--set recap.sentences: recap.sentences takes N or N-M (1-10), not "11"',
        "recap.sentences=4-2" => '--set recap.sentences: recap.sentences takes N or N-M (1-10), not "4-2"'
      }.each do |arg, message|
        expect { parse(arg) }.to raise_error(described_class::Error, message), arg
      end
    end

    it "refuses a core key no session sets, naming the ones it may (not a bundle error)" do
      expect { parse("guardrails.mode=strict") }
        .to raise_error(described_class::Error, "--set guardrails.mode: guardrails.mode is not a session setting " \
                                                "(session settings: recap.enabled, recap.sentences)")
      expect { parse("web.port=1") }.to raise_error(described_class::Error, /\A--set web\.port: web\.port is not a session setting/)
    end

    it "takes a dotless key as core only: an unknown one names the session settings and the bundles that take --set" do
      expect { parse("foo=1") }
        .to raise_error(described_class::Error, "--set foo: no session setting foo (session settings: recap.enabled, " \
                                                "recap.sentences; bundles that take --set: cost-cap)")
      expect { parse("skip_agents_md=true") }
        .to raise_error(described_class::Error, /\A--set skip_agents_md: skip_agents_md is not a session setting/)
    end

    it "says did-you-mean for an unknown key under a core section no bundle takes (.check!)" do
      expect { described_class.check!(parse("recap.enable=false"), bundles: offered) }
        .to raise_error(described_class::Error, "--set recap.enable: no session setting recap.enable (did you mean recap.enabled?)")
      expect { described_class.check!(parse("recap.zzz=1"), bundles: offered) }
        .to raise_error(described_class::Error, "--set recap.zzz: no session setting recap.zzz " \
                                                "(session settings: recap.enabled, recap.sentences)")
    end

    it "keeps BUNDLE.KEY for a bundle named like a core section when the key isn't a core one" do
      settings = parse("recap.extra=1")
      expect(described_class.check!(settings, bundles: { "recap" => ["extra"] })).to equal(settings)
    end
  end

  describe ".clash" do
    it "names a bundle's session setting that is chi's own NAME.KEY, nil otherwise" do
      expect(described_class.clash("recap", %w[enabled other]))
        .to eq("session_settings: recap.enabled is chi's own session setting (--set recap.enabled=… sets chi's); " \
               "rename the setting or the bundle")
      expect(described_class.clash("recap", %w[other])).to be_nil
      expect(described_class.clash("guardrails", %w[mode])).to be_nil
    end
  end

  describe ".typed" do
    it "types integers, decimals (.5, 5., 1e3 too) and YAML's booleans; keeps everything else as the string given" do
      {
        "3" => 3, "-1" => -1, "0" => 0, "2.5" => 2.5, "-0.25" => -0.25, ".5" => 0.5, "-.5" => -0.5, "5." => 5.0,
        "1e3" => 1000.0, "1E1" => 10.0, "2.5e-1" => 0.25, "-1e1" => -10.0,
        "true" => true, "True" => true, "yes" => true, "on" => true, "ON" => true,
        "false" => false, "off" => false, "Off" => false, "no" => false, "No" => false, "NO" => false,
        "3:30" => "3:30", "010" => "010", "0x10" => "0x10", "00.5" => "00.5", "e3" => "e3", "1e" => "1e", "." => ".",
        "y" => "y", "n" => "n", "null" => "null", "~" => "~", "1_000" => "1_000", "2026-10-18" => "2026-10-18",
        "$3" => "$3", "[1, 2]" => "[1, 2]", "five" => "five"
      }.each do |given, value|
        expect(described_class.typed(given)).to eql(value), given
      end
    end

    it "keeps 1e400 as text: Infinity is no number a setting can use or JSON save" do
      expect(described_class.typed("1e400")).to eq("1e400")
      expect(described_class.typed("-1e400")).to eq("-1e400")
    end

    it "reads 5. and 5.e1 as Ruby 3.3's Float does (a 0 after a bare point)" do
      expect(described_class.float_text("5.")).to eq("5.0")
      expect(described_class.float_text("5.e1")).to eq("5.0e1")
      expect(described_class.float_text("-5.E1")).to eq("-5.0E1")
      expect(described_class.float_text("2.5e1")).to eq("2.5e1")
      expect(described_class.typed("5.e1")).to eq(50.0)
    end

    it "keeps what isn't a String (a JSON number or boolean) as it is" do
      [3, 2.5, true, false].each { |value| expect(described_class.typed(value)).to eql(value) }
    end
  end

  describe ".check!" do
    it "takes the keys an installed bundle offers" do
      settings = parse("cost-cap.cap=off")
      expect(described_class.check!(settings, bundles: offered)).to equal(settings)
    end

    it "refuses a bundle that isn't installed, naming the ones that take --set" do
      expect { described_class.check!(parse("nope.x=1"), bundles: offered) }
        .to raise_error(described_class::Error, "--set nope.x: no installed bundle nope (bundles that take --set: cost-cap)")
      expect { described_class.check!(parse("nope.x=1"), bundles: { "loop-guard" => [] }) }
        .to raise_error(described_class::Error, "--set nope.x: no installed bundle nope (no installed bundle takes --set)")
    end

    it "refuses a key the bundle doesn't list, naming the ones it takes" do
      expect { described_class.check!(parse("cost-cap.default=1"), bundles: offered) }
        .to raise_error(described_class::Error, "--set cost-cap.default: cost-cap takes cap")
      expect { described_class.check!(parse("loop-guard.limit=3"), bundles: offered) }
        .to raise_error(described_class::Error, "--set loop-guard.limit: loop-guard takes no session settings")
    end

    it "refuses a value of the wrong type for a key the manifest types (session_settings: {cap: number})" do
      types = { "cost-cap" => { "cap" => "number" } }
      %w[cap=3 cap=0.5 cap=.5 cap=1e1 cap=-1 cap=0 cap=off cap=false].each do |pair|
        settings = parse("cost-cap.#{pair}")
        expect(described_class.check!(settings, bundles: offered, types: types)).to equal(settings), pair
      end
      { "five" => "\"five\"", "0x10" => "\"0x10\"", "on" => "true", "$3" => "\"$3\"" }.each do |value, shown|
        expect { described_class.check!(parse("cost-cap.cap=#{value}"), bundles: offered, types: types) }
          .to raise_error(described_class::Error, "--set cost-cap.cap: cost-cap takes a number (or off) for cap, not #{shown}"), value
      end
      expect { described_class.check!({ "cost-cap" => { "cap" => "x" } }, bundles: offered, types: types, flag: "settings") }
        .to raise_error(described_class::Error, /\Asettings cost-cap\.cap: cost-cap takes a number/)
    end

    it "refuses a number that isn't finite under number" do
      expect do
        described_class.check!({ "cost-cap" => { "cap" => Float::INFINITY } }, bundles: offered,
                                                                                  types: { "cost-cap" => { "cap" => "number" } })
      end
        .to raise_error(described_class::Error, "--set cost-cap.cap: cost-cap takes a number (or off) for cap, not Infinity")
      expect { described_class.check!(parse("cost-cap.cap=1e400"), bundles: offered, types: { "cost-cap" => { "cap" => "number" } }) }
        .to raise_error(described_class::Error, /takes a number \(or off\) for cap, not "1e400"/)
    end

    it "checks boolean and string types, and takes any value for an untyped key" do
      bundles = { "b" => %w[flag name free] }
      types = { "b" => { "flag" => "boolean", "name" => "string" } }
      settings = parse("b.flag=no", "b.name=fast", "b.free=3")
      expect(described_class.check!(settings, bundles: bundles, types: types)).to equal(settings)
      expect { described_class.check!(parse("b.flag=3"), bundles: bundles, types: types) }
        .to raise_error(described_class::Error, "--set b.flag: b takes true or false for flag, not 3")
      expect { described_class.check!(parse("b.name=3"), bundles: bundles, types: types) }
        .to raise_error(described_class::Error, "--set b.name: b takes text for name, not 3")
    end

    it "names the request field instead of --set when given one" do
      expect { described_class.check!({ "nope" => { "x" => 1 } }, bundles: offered, flag: "settings") }
        .to raise_error(described_class::Error, /\Asettings nope\.x: no installed bundle nope/)
    end
  end

  describe ".availability" do
    let(:dir) { Dir.mktmpdir("bundles") }

    after { FileUtils.rm_rf(dir) }

    # A record as an install leaves it; +plugin+ writes plugin/plugin.rb
    # with its sha recorded (+sha+ overrides the recorded one).
    def record(name, plugin: true, sha: nil, **fields)
      FileUtils.mkdir_p(File.join(dir, name, "plugin"))
      data = { "name" => name, "version" => "1.0.0" }.merge(fields.transform_keys(&:to_s))
      if plugin
        File.write(File.join(dir, name, "plugin", "plugin.rb"), "class Plugin; end\n")
        data["plugin"] = { "file" => "plugin.rb",
                           "sha256" => sha || "sha256:#{Digest::SHA256.hexdigest("class Plugin; end\n")}" }
      end
      File.write(File.join(dir, name, "manifest.json"), JSON.generate(data))
    end

    it "offers the session_settings of each installed bundle whose plugin loads, a bad record left out" do
      record("mine", session_settings: ["cap"])
      record("plain", plugin: false)
      FileUtils.mkdir_p(File.join(dir, "broken"))
      File.write(File.join(dir, "broken", "manifest.json"), "{")

      available = described_class.availability(dir: dir)
      expect(available.offered).to eq("mine" => ["cap"], "plain" => [])
      expect(available.notes).to eq({})
      expect(available.types).to eq({})
      expect(described_class.offered(dir: dir)).to eq("mine" => ["cap"], "plain" => [])
    end

    it "leaves out a bundle whose plugin doesn't load (requires_chi, an edited file), saying why" do
      record("future", session_settings: ["cap"], requires_chi: ">= 99.0")
      record("edited", session_settings: ["cap"], sha: "sha256:#{"0" * 64}")

      available = described_class.availability(dir: dir)
      expect(available.offered).to eq({})
      expect { described_class.check!(parse("future.cap=1"), bundles: available.offered, notes: available.notes) }
        .to raise_error(described_class::Error, /\A--set future\.cap: future is installed but its plugin doesn't load: it requires chi >= 99\.0/)
      expect { described_class.check!(parse("edited.cap=1"), bundles: available.offered, notes: available.notes) }
        .to raise_error(described_class::Error, /\A--set edited\.cap: edited is installed but its plugin doesn't load: its sha256 [0-9a-f]{12}… differs from the installed 000000000000…/)
    end

    it "keeps a string key's text as given: yes, 5, 1.10 and 1e3 aren't typed for it" do
      available = described_class::Availability.new(offered: { "b" => %w[name free] }, notes: {},
                                                    types: { "b" => { "name" => "string" } })
      %w[yes 5 1.10 1e3].each do |text|
        expect(described_class.from_flags(["b.name=#{text}", "b.free=#{text}"], available: available).bundles["b"])
          .to eq("name" => text, "free" => described_class.typed(text)), text
        expect(described_class.from_request({ "b.name" => text }, bundles: available.offered, types: available.types).bundles)
          .to eq("b" => { "name" => text }), text
      end
      expect(described_class.from_flags(["b.free=yes"], available: available).bundles).to eq("b" => { "free" => true })
    end

    it "keeps the types a record lists (session_setting_types), and from_flags checks them" do
      record("mine", session_settings: %w[cap note], session_setting_types: { "cap" => "number" })

      available = described_class.availability(dir: dir)
      expect(available.types).to eq("mine" => { "cap" => "number" })
      expect(described_class.from_flags(["mine.cap=.5"], available: available).bundles).to eq("mine" => { "cap" => 0.5 })
      expect { described_class.from_flags(["mine.cap=five"], available: available) }
        .to raise_error(described_class::Error, "--set mine.cap: mine takes a number (or off) for cap, not \"five\"")
    end

    it "says how to refresh a record from before session_settings when the shipped bundle lists them" do
      record("cost-cap")
      record("plain")

      available = described_class.availability(dir: dir)
      expect { described_class.check!(parse("cost-cap.cap=1"), bundles: available.offered, notes: available.notes) }
        .to raise_error(described_class::Error, "--set cost-cap.cap: cost-cap takes no session settings " \
                                                "(run `chi update` or `chi bundle upgrade cost-cap` to refresh it)")
      expect { described_class.check!(parse("plain.cap=1"), bundles: available.offered, notes: available.notes) }
        .to raise_error(described_class::Error, "--set plain.cap: plain takes no session settings")
    end
  end

  describe ".from_request" do
    def request(raw, **opts) = described_class.from_request(raw, bundles: offered, **opts)

    it "takes an object of names as --set gives them to scalars, checked like --set, a string typed as --set types it" do
      expect(request({ "cost-cap.cap" => 2.5 }).bundles).to eq("cost-cap" => { "cap" => 2.5 })
      expect(request({ "cost-cap.cap" => "3" }).bundles).to eq("cost-cap" => { "cap" => 3 })
      expect(request({ "cost-cap.cap" => "off" }).bundles).to eq("cost-cap" => { "cap" => false })
      expect(request({ "cost-cap.cap" => "010" }).bundles).to eq("cost-cap" => { "cap" => "010" })
      expect(request(nil)).to equal(described_class::Settings::EMPTY)
      expect(request({})).to equal(described_class::Settings::EMPTY)
    end

    it "takes core keys too, JSON booleans and numbers typed by their entry" do
      expect(request({ "recap.enabled" => false, "recap.sentences" => 3, "cost-cap.cap" => 1 }))
        .to have_attributes(core: { "recap.enabled" => false, "recap.sentences" => "3" }, bundles: { "cost-cap" => { "cap" => 1 } })
      expect { request({ "recap.enabled" => "maybe" }) }
        .to raise_error(described_class::Error, 'settings recap.enabled: recap.enabled takes true or false, not "maybe"')
      expect { request({ "guardrails.mode" => "strict" }) }
        .to raise_error(described_class::Error, /\Asettings guardrails\.mode: guardrails\.mode is not a session setting/)
      expect { request({ "recap.enabled" => " " }) }.to raise_error(described_class::Error, "settings recap.enabled: give a value")
    end

    it "checks the types as --set does" do
      types = { "cost-cap" => { "cap" => "number" } }
      expect(request({ "cost-cap.cap" => ".5" }, types: types).bundles).to eq("cost-cap" => { "cap" => 0.5 })
      expect { request({ "cost-cap.cap" => "five" }, types: types) }
        .to raise_error(described_class::Error, "settings cost-cap.cap: cost-cap takes a number (or off) for cap, not \"five\"")
    end

    it "refuses another shape" do
      [[1], { "cost-cap" => { "cap" => 3 } }, { "cost-cap.cap" => [1] }, { "cost-cap.cap" => nil }].each do |raw|
        expect { request(raw) }
          .to raise_error(described_class::Error, "settings is an object of KEY or BUNDLE.KEY => scalar"), raw.inspect
      end
      expect { request({ "a b" => 1 }) }.to raise_error(described_class::Error, 'settings takes KEY or BUNDLE.KEY names, not "a b"')
      expect { request({ "cost-cap.default" => 1 }) }
        .to raise_error(described_class::Error, "settings cost-cap.default: cost-cap takes cap")
    end
  end

  describe ".normalize" do
    it "reads a session file's value tolerantly: string keys, scalars only, frozen; {} for anything else" do
      expect(described_class.normalize(nil)).to eq({})
      expect(described_class.normalize("x")).to eq({})
      normalized = described_class.normalize({ "cost-cap" => { "cap" => 3, "bad" => [1] }, "x" => 1, b: { k: true },
                                               "empty" => {}, "only_bad" => { "a" => nil } })
      expect(normalized).to eq("cost-cap" => { "cap" => 3 }, "b" => { "k" => true })
      expect(normalized).to be_frozen
      expect(normalized["cost-cap"]).to be_frozen
    end
  end

  describe "Settings" do
    it "keeps core and bundles frozen and string-keyed, both empty by default" do
      settings = described_class::Settings.new(core: { "recap.enabled": true, bad: [1] }, bundles: { "cost-cap": { cap: 3 } })
      expect(settings).to have_attributes(core: { "recap.enabled" => true }, bundles: { "cost-cap" => { "cap" => 3 } })
      expect([settings.core, settings.bundles]).to all(be_frozen)
      expect(settings).not_to be_empty
      expect(described_class::Settings.new).to be_empty.and eq(described_class::Settings::EMPTY)
    end

    it "reads core tolerantly: only session-settable keys whose value types as their entry and passes its check, typed" do
      settings = described_class::Settings.new(core: { "recap.enabled" => "no", "recap.sentences" => "99", "guardrails.mode" => "strict",
                                                       "x" => 1, "recap.model" => "m" })
      expect(settings.core).to eq("recap.enabled" => false)
      expect(described_class::Settings.new(core: { "recap.enabled" => "maybe", "recap.sentences" => 2 }).core)
        .to eq("recap.sentences" => "2")
      expect(described_class.normalize_core("x")).to eq({})
    end

    it "names both parts as --set does (flat, text)" do
      settings = described_class::Settings.new(core: { "recap.enabled" => false }, bundles: { "cost-cap" => { "cap" => 3 } })
      expect(settings.flat).to eq("recap.enabled" => false, "cost-cap.cap" => 3)
      expect(settings.text).to eq("recap.enabled=false · cost-cap.cap=3")
      expect(described_class::Settings::EMPTY.text).to eq("")
    end

    it "takes a Settings as given and nil as none (.of); refuses anything else" do
      settings = described_class::Settings.new(bundles: { "x" => { "k" => 1 } })
      expect(described_class::Settings.of(settings)).to equal(settings)
      expect(described_class::Settings.of(nil)).to equal(described_class::Settings::EMPTY)
      expect { described_class::Settings.of({ "x" => { "k" => 1 } }) }.to raise_error(ArgumentError, /SessionConfig::Settings/)
    end
  end
end
