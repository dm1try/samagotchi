# frozen_string_literal: true

require "json"
require "samagotchi/terminal_ui"
require "samagotchi/served_model"

# Shared contract: spec/shared/labels_matrix.json, the words the TUI and the
# web put on the same event. spec/web/public/labels_matrix.test.js reads the
# same file; edit it to change either side's words.
RSpec.describe "Shared labels matrix (TUI side)" do
  matrix = JSON.parse(File.read(File.expand_path("shared/labels_matrix.json", __dir__)))

  def self.cases(matrix, section) = matrix.fetch(section).fetch("cases")

  # The Ruby expectation of a case: its own, else the shared one.
  def expected(entry) = entry.key?("ruby") ? entry["ruby"] : entry["expected"]

  let(:fmt) do
    Class.new do
      include Samagotchi::TerminalUI::Formatting

      def color_output? = false
    end.new
  end

  def event(hash) = Samagotchi::TerminalUI::EventRenderer.symbolize(hash)

  cases(matrix, "cancel_reasons").each do |entry|
    it "names cancel reason #{entry["reason"].inspect}" do
      label = expected(entry)
      expect(fmt.turn_canceled_line(entry["reason"], nil)).to eq("✕ turn canceled#{" (#{label})" if label}")
    end
  end

  cases(matrix, "cancelled_by").each do |entry|
    it "names who stopped a #{entry["reason"]} turn: #{entry["by"].inspect}" do
      expect(fmt.turn_canceled_line(entry["reason"], nil, by: entry["by"])).to eq("✕ turn #{expected(entry)}")
    end
  end

  cases(matrix, "client_labels").each do |entry|
    it "labels a prompt from #{entry["client_id"].inspect}" do
      expect(fmt.prompt_line(entry["client_id"], "hi")).to eq("#{expected(entry)}> hi")
    end
  end

  cases(matrix, "hook_notice_labels").each do |entry|
    it "labels a notice from hook #{entry["hook"].inspect}" do
      line = Samagotchi::TerminalUI::EventRenderer.hook_notice_line({ hook: entry["hook"], text: "x" })
      expect(line).to eq("#{expected(entry)}> x")
    end
  end

  cases(matrix, "empty_retry_lines").each do |entry|
    it "words the empty-answer retry #{entry["event"].inspect}" do
      expect(fmt.format_empty_retry_line(event(entry["event"]))).to eq(expected(entry))
    end
  end

  cases(matrix, "steer_cut_lines").each do |entry|
    it "words the steer cut #{entry["event"].inspect}" do
      expect(fmt.format_steer_cut_line(event(entry["event"]))).to eq(expected(entry))
    end
  end

  cases(matrix, "steer_senders").each do |entry|
    it "names the steer sender #{entry["source"].inspect}" do
      expect(fmt.steer_sender(entry["source"])).to eq(expected(entry))
      who = expected(entry).empty? ? "plugin" : expected(entry)
      expect(fmt.format_steer_line(source: entry["source"], text: "go")).to eq("#{who}> nudged: go")
    end
  end

  cases(matrix, "empty_answer_lines").each do |entry|
    it "words the no-answer notice after #{entry["retries"]} retries" do
      expect(fmt.format_empty_answer_line(entry["retries"])).to eq(expected(entry))
    end
  end

  cases(matrix, "retry_lines").each do |entry|
    it "words the provider retry #{entry["event"].inspect}" do
      expect(fmt.format_generation_retry_line(event(entry["event"]))).to eq(expected(entry))
    end
  end

  cases(matrix, "reminder_lines").each do |entry|
    it "words the reminders #{entry["reminders"].inspect}" do
      reminders = Samagotchi::TerminalUI::EventRenderer.deep_symbolize_keys(entry["reminders"])
      expect(fmt.reminder_line(reminders)).to eq(expected(entry))
    end
  end

  cases(matrix, "served_model").each do |entry|
    it "tells #{entry["served"].inspect} served for #{entry["asked"].inspect} #{entry["differs"] ? "differs" : "is the same"}" do
      expect(Samagotchi::ServedModel.differs?(entry["asked"], entry["served"])).to eq(entry["differs"])
    end
  end

  cases(matrix, "speeds").each do |entry|
    it "words the speed #{entry["tps"].inspect} (#{entry["source"]})" do
      expect(fmt.speed_text(entry["tps"], entry["source"])).to eq(expected(entry))
    end
  end

  cases(matrix, "costs").each do |entry|
    it "words the cost #{entry["cost"].inspect}" do
      expect(fmt.cost_text(entry["cost"])).to eq(expected(entry))
    end
  end
end
