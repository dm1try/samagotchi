# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "digest"
require "spec_helper"
require "samagotchi/bundle_session_settings"

# --set BUNDLE.KEY=VALUE: the values parsed as YAML scalars, then checked
# against the installed bundles and the keys their manifests offer
# (session_settings:).
RSpec.describe Samagotchi::BundleSessionSettings do
  let(:offered) { { "cost-cap" => ["cap"], "loop-guard" => [] } }

  def parse(*args) = described_class.parse(args)

  describe ".parse" do
    it "reads BUNDLE.KEY=VALUE, typing the value, by bundle" do
      expect(parse("cost-cap.cap=3", "cost-cap.note='5'", "other.on=true", "other.ratio=2.5", "other.name=fast lane"))
        .to eq("cost-cap" => { "cap" => 3, "note" => "'5'" },
               "other" => { "on" => true, "ratio" => 2.5, "name" => "fast lane" })
    end

    it "lets a later --set of the same key win" do
      expect(parse("cost-cap.cap=3", "cost-cap.cap=0.5")).to eq("cost-cap" => { "cap" => 0.5 })
    end

    it "keeps a = in the value" do
      expect(parse("a.expr=x=1")).to eq("a" => { "expr" => "x=1" })
    end

    it "returns a frozen Hash" do
      settings = parse("cost-cap.cap=3")
      expect(settings).to be_frozen
      expect(settings["cost-cap"]).to be_frozen
    end

    it "refuses the shapes that aren't BUNDLE.KEY=VALUE" do
      {
        "foo" => "--set takes BUNDLE.KEY=VALUE, not foo",
        "foo=1" => "--set takes BUNDLE.KEY=VALUE, not foo=1",
        ".k=v" => "--set takes BUNDLE.KEY=VALUE, not .k=v",
        "b.=v" => "--set takes BUNDLE.KEY=VALUE, not b.=v",
        "a.b.c=1" => "--set a.b.c=1: one key under the bundle (BUNDLE.KEY), no nested path",
        "a b.c=1" => "--set takes BUNDLE.KEY=VALUE, not a b.c=1",
        "a.b=" => "--set a.b=: give a value"
      }.each do |arg, message|
        expect { parse(arg) }.to raise_error(described_class::Error, message), arg
      end
    end
  end

  describe ".typed" do
    it "types integers, decimals, true, false and off; keeps everything else as the string given" do
      {
        "3" => 3, "-1" => -1, "0" => 0, "2.5" => 2.5, "-0.25" => -0.25, "true" => true, "false" => false, "off" => false,
        "3:30" => "3:30", "010" => "010", "0x10" => "0x10", "No" => "No", "no" => "no", "on" => "on", "yes" => "yes",
        "null" => "null", "~" => "~", "1_000" => "1_000", "1e3" => "1e3", "2026-10-18" => "2026-10-18", "$3" => "$3",
        "[1, 2]" => "[1, 2]", "True" => "True", ".5" => ".5", "5." => "5.", "00.5" => "00.5"
      }.each do |given, value|
        expect(described_class.typed(given)).to eql(value), given
      end
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

    it "names the request field instead of --set when given one" do
      expect { described_class.check!({ "nope" => { "x" => 1 } }, bundles: offered, flag: "bundle_settings") }
        .to raise_error(described_class::Error, /\Abundle_settings nope\.x: no installed bundle nope/)
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
        .to raise_error(described_class::Error, /\A--set edited\.cap: edited is installed but its plugin doesn't load: its sha256/)
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
    it "takes an object of objects of scalars, checked like --set, a string typed as --set types it" do
      expect(described_class.from_request({ "cost-cap" => { "cap" => 2.5 } }, bundles: offered))
        .to eq("cost-cap" => { "cap" => 2.5 })
      expect(described_class.from_request({ "cost-cap" => { "cap" => "3" } }, bundles: offered)).to eq("cost-cap" => { "cap" => 3 })
      expect(described_class.from_request({ "cost-cap" => { "cap" => "off" } }, bundles: offered)).to eq("cost-cap" => { "cap" => false })
      expect(described_class.from_request({ "cost-cap" => { "cap" => "010" } }, bundles: offered)).to eq("cost-cap" => { "cap" => "010" })
      expect(described_class.from_request(nil, bundles: offered)).to eq({})
    end

    it "drops an empty bundle entry before checking it" do
      expect(described_class.from_request({ "cost-cap" => {}, "nope" => {} }, bundles: offered)).to eq({})
    end

    it "refuses another shape" do
      [[1], { "cost-cap" => 3 }, { "cost-cap" => { "cap" => [1] } }, { "cost-cap" => { "cap" => { "a" => 1 } } }].each do |raw|
        expect { described_class.from_request(raw, bundles: offered) }
          .to raise_error(described_class::Error, /bundle_settings is an object of bundle => \{key => scalar\}/), raw.inspect
      end
      expect { described_class.from_request({ "cost-cap" => { "default" => 1 } }, bundles: offered) }
        .to raise_error(described_class::Error, "bundle_settings cost-cap.default: cost-cap takes cap")
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
end
