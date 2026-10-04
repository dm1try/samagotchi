# frozen_string_literal: true

require "spec_helper"
require "samagotchi/web/qr"

RSpec.describe Samagotchi::Web::QR do
  let(:link) { "http://192.168.1.55:4567/?token=#{"t" * 43}" }

  it "puts the code in a quiet zone of 2 white modules" do
    rows = described_class.matrix(link)
    size = RQRCodeCore::QRCode.new(link, level: :l).module_count

    expect(rows.size).to eq(size + 4)
    expect(rows.map(&:size).uniq).to eq([size + 4])
    [0, 1, -1, -2].each { |r| expect(rows[r]).to all(be false) }
    expect(rows.map { |r| r[0] || r[1] || r[-1] || r[-2] }).to all(be false)
    expect(rows[2][2]).to be true # the finder pattern's corner
  end

  it "draws two rows per line in half blocks, black on white" do
    lines = described_class.lines(link)
    plain = described_class.lines(link, color: false)
    rows = described_class.matrix(link)

    expect(plain.size).to eq((rows.size + 1) / 2)
    expect(plain.map { |l| l.size }.uniq).to eq([rows.first.size])
    expect(plain.join).to match(/\A[ ▀▄█]+\z/)
    expect(plain.first).to eq(" " * rows.first.size)
    expect(plain[1][2]).to eq("█") # rows 2 and 3: the finder's top edge
    expect(lines.first).to start_with("\e[30;107m").and end_with("\e[0m")
  end

  it "is a version-4 code (33 modules, 19 lines) for a LAN link" do
    expect(described_class.lines(link, color: false).size).to eq(19)
  end
end
