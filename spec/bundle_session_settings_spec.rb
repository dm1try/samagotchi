# frozen_string_literal: true

require "json"
require "tmpdir"
require "fileutils"
require "spec_helper"
require "samagotchi/bundle_session_settings"

# --set BUNDLE.KEY=VALUE: the values parsed as YAML scalars, then checked
# against the installed bundles and the keys their manifests offer
# (session_settings:).
RSpec.describe Samagotchi::BundleSessionSettings do
  let(:offered) { { "cost-cap" => ["cap"], "loop-guard" => [] } }

  def parse(*args) = described_class.parse(args)

  describe ".parse" do
    it "reads BUNDLE.KEY=VALUE as YAML scalars, by bundle" do
      expect(parse("cost-cap.cap=3", "cost-cap.note='5'", "other.on=true", "other.ratio=2.5", "other.name=fast lane"))
        .to eq("cost-cap" => { "cap" => 3, "note" => "5" },
               "other" => { "on" => true, "ratio" => 2.5, "name" => "fast lane" })
    end

    it "lets a later --set of the same key win" do
      expect(parse("cost-cap.cap=3", "cost-cap.cap=0.5")).to eq("cost-cap" => { "cap" => 0.5 })
    end

    it "reads off, no, on and yes as booleans, and keeps text it can't read as text" do
      expect(parse("a.x=off", "a.y=no", "a.z=on", "a.w=yes", "a.d=2026-10-18", "a.v=$3"))
        .to eq("a" => { "x" => false, "y" => false, "z" => true, "w" => true, "d" => "2026-10-18", "v" => "$3" })
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
        "a.b=" => "--set a.b=: give a value",
        "a.b=[1, 2]" => "--set a.b=[1, 2]: the value is a YAML scalar (3, 2.5, true, text)",
        "a.b={x: 1}" => "--set a.b={x: 1}: the value is a YAML scalar (3, 2.5, true, text)"
      }.each do |arg, message|
        expect { parse(arg) }.to raise_error(described_class::Error, message), arg
      end
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

  describe ".offered" do
    it "reads each installed bundle's session_settings from its record, a bad record left out" do
      dir = Dir.mktmpdir("bundles")
      { "cost-cap" => { "name" => "cost-cap", "session_settings" => ["cap"] }, "plain" => { "name" => "plain" } }
        .each do |name, record|
          FileUtils.mkdir_p(File.join(dir, name))
          File.write(File.join(dir, name, "manifest.json"), JSON.generate(record))
        end
      FileUtils.mkdir_p(File.join(dir, "broken"))
      File.write(File.join(dir, "broken", "manifest.json"), "{")

      expect(described_class.offered(dir: dir)).to eq("cost-cap" => ["cap"], "plain" => [])
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  describe ".from_request" do
    it "takes an object of objects of scalars, checked like --set" do
      expect(described_class.from_request({ "cost-cap" => { "cap" => 2.5 } }, bundles: offered))
        .to eq("cost-cap" => { "cap" => 2.5 })
      expect(described_class.from_request(nil, bundles: offered)).to eq({})
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
      normalized = described_class.normalize({ "cost-cap" => { "cap" => 3, "bad" => [1] }, "x" => 1, b: { k: true } })
      expect(normalized).to eq("cost-cap" => { "cap" => 3 }, "b" => { "k" => true })
      expect(normalized).to be_frozen
      expect(normalized["cost-cap"]).to be_frozen
    end
  end
end
