# frozen_string_literal: true

require "samagotchi/web/editor"

RSpec.describe Samagotchi::Web::Editor do
  it "turns a preset name into its URL template" do
    expect(described_class.template("vscode")).to eq("vscode://file{path}:{line}")
    expect(described_class.template("vscode-insiders")).to eq("vscode-insiders://file{path}:{line}")
    expect(described_class.template("cursor")).to eq("cursor://file{path}:{line}")
    expect(described_class.template("zed")).to eq("zed://file{path}:{line}")
    expect(described_class.template(" VSCode ")).to eq("vscode://file{path}:{line}")
  end

  it "keeps a template that has {path}, {line} optional" do
    expect(described_class.template("idea://open?file={path}&line={line}")).to eq("idea://open?file={path}&line={line}")
    expect(described_class.template("subl://open?url=file://{path}")).to eq("subl://open?url=file://{path}")
  end

  it "has none for none, empty, or an unknown name (logged once)" do
    expect(described_class.template("none")).to be_nil
    expect(described_class.template("")).to be_nil
    expect(described_class.template(nil)).to be_nil
    allow(Samagotchi::Log).to receive(:warn)
    expect(described_class.template("emacs")).to be_nil
    expect(Samagotchi::Log).to have_received(:warn).with(:web, "editor_unknown", value: "emacs").once
  end
end
