# frozen_string_literal: true

require_relative "../../script/affected_specs/changed_defs"

# The methods a change touches, by line, with Prism.
RSpec.describe AffectedSpecs::ChangedDefs do
  let(:source) do
    <<~RUBY
      class Outer
        def self.build(x)
          x
        end

        def wrap
          def inner
            1
          end
          2
        end

        def size = 3
      end
    RUBY
  end

  it "is available on this Ruby's Prism" do
    expect(described_class.available?).to be(true)
  end

  it "names the innermost def around each line, in source order, once" do
    expect(described_class.names(source, [13, 8, 10, 7, 3])).to eq(%w[build wrap inner size])
  end

  it "names `def self.x` by its name and an endless def by its line" do
    expect(described_class.names(source, [2])).to eq(%w[build])
    expect(described_class.names(source, [13])).to eq(%w[size])
  end

  it "names nothing for lines outside any def, or no lines" do
    expect(described_class.names(source, [1, 5, 14])).to eq([])
    expect(described_class.names(source, [])).to eq([])
  end

  it "still names the defs of a source with a syntax error" do
    expect(described_class.names("def ok\n  1\nend\n\ndef broken(\n  2\n", [2])).to eq(%w[ok])
  end

  it "names nothing when Prism is below 1.0" do
    allow(described_class).to receive(:available?).and_return(false)

    expect(described_class.names(source, [3])).to eq([])
  end
end
