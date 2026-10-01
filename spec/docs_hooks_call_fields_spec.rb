# frozen_string_literal: true

require "samagotchi/tools/builtin_calls"

# docs/hooks.md's "The call a hook sees" table says, per built-in, which
# parameter fills content: and path: and which keep their own field; it
# must match Tools::BuiltinCalls.
RSpec.describe "docs/hooks.md built-in call fields" do
  let(:doc) { File.read(File.expand_path("../docs/hooks.md", __dir__)) }

  def code_list(keys, joiner = ", ") = keys.empty? ? "—" : keys.map { |key| "`#{key}`" }.join(joiner)

  it "has a row per built-in that matches its mapping" do
    expected = Samagotchi::Tools::BuiltinCalls.rows.each_value.map do |row|
      path = row.path_key ? "`#{row.path_key}`" : "—"
      "| `#{row.name}` | #{code_list(row.content_keys, ' or ')} | #{path} | #{code_list(row.fields)} |"
    end
    documented = doc.lines.map(&:chomp).select { |line| line.match?(/\A\| `[a-z_]+` \|/) }

    expect(documented).to eq(expected)
  end
end
