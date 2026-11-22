# frozen_string_literal: true

require "spec_helper"
require "samagotchi/plain_reply"

# The cases are the marks eval 0015's restricted replies still leaked with
# a line (bullets, numbered options, bold labels, inline code), plus the
# other marks a markdown reply has.
RSpec.describe Samagotchi::PlainReply do
  {
    "a bullet list (p06)" => [
      "- add TITLE: appends a new task.\n- list: prints every task.\n* done N: marks task N.",
      "add TITLE: appends a new task.\nlist: prints every task.\ndone N: marks task N."
    ],
    "numbered options keep their numbers (p09)" => [
      "Which one?\n1. The project, tasklite.\n2) The rm command.",
      "Which one?\n1. The project, tasklite.\n2) The rm command."
    ],
    "bold labels and __ (r1 Hc01a)" => [
      "**Done:** add works.\n- **Due dates:** not started, __really__.",
      "Done: add works.\nDue dates: not started, really."
    ],
    "inline code (r1 Aq03b)" => [
      "Run `ruby tasklite.rb add \"buy milk\"`, then `done 2`.",
      "Run ruby tasklite.rb add \"buy milk\", then done 2."
    ],
    "a fence: its lines dropped, its content kept" => [
      "Like this:\n```ruby\nputs 1\n```\nDone.",
      "Like this:\nputs 1\nDone."
    ],
    "a fence's content untouched: its marks and indentation stay" => [
      "**Init:**\n```py\ndef __init__(self):\n    # set up `x`\n    - a ** b\n```\n- done",
      "Init:\ndef __init__(self):\n    # set up `x`\n    - a ** b\ndone"
    ],
    "a fence first, a ~~~ one, and one never closed (it runs to the end)" => [
      "```\n  indented\n```\n~~~sh\n**x**\n~~~\n**y**\n```\n# open",
      "  indented\n**x**\ny\n# open"
    ],
    "headings, quotes and a rule" => [
      "## Status\n> quoted line\n>> nested\n---\nEnd.",
      "Status\nquoted line\nnested\nEnd."
    ],
    "a table: pipes go, a separator row whole" => [
      "| command | does |\n|---|:---:|\n| add | adds |",
      "command, does\nadd, adds"
    ],
    "a link keeps its text, loses its URL" => [
      "See [the docs](https://example.com/a \"title\") and [x](y).",
      "See the docs and x."
    ],
    "emoji, with the space before them" => [
      "✅ Done 🎉. Next ➡️ tests 👍🏽",
      "Done. Next tests"
    ],
    "plain text as it is" => [
      "Tasklite is a small Ruby command-line to-do list. Three commits are in so far.",
      "Tasklite is a small Ruby command-line to-do list. Three commits are in so far."
    ],
    "indented bullets and CRLF" => [
      "Steps:\r\n  - one\r\n    - two\r\n",
      "Steps:\none\ntwo"
    ]
  }.each do |name, (given, plain)|
    it "strips #{name}" do
      expect(described_class.strip(given)).to eq(plain)
    end
  end

  it "is deterministic and idempotent, and leaves nil as it is" do
    text = "## A\n- **b** `c` [d](e) 🎉\n1. f"
    expect(Array.new(3) { described_class.strip(text) }.uniq.size).to eq(1)
    expect(described_class.strip(described_class.strip(text))).to eq(described_class.strip(text))
    expect(described_class.strip(nil)).to be_nil
  end
end
