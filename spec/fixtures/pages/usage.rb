# frozen_string_literal: true

# The map's usage page, reading a saved `chi-usage --days 7 --format json`
# (usage.json beside it) instead of running the program.
page "Usage, last 7 days" do |ui|
  data = JSON.parse(File.read(File.join(__dir__, "usage.json")))
  ui.text "Stored cost per model. #{data["totals"]["turns"]} turns."
  ui.table data["groups"].map { |model, g| g.merge("model" => model) },
           columns: { "model" => "Model", "turns" => "Turns", "cost" => "Stored" },
           format: { "cost" => :money }, key: %w[turns cost],
           total: { "model" => "Total", "turns" => data["totals"]["turns"], "cost" => data["totals"]["cost"] }
end
