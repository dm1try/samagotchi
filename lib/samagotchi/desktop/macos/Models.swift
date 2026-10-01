// The new session's model: `chi models --format json` (every host's
// listing and the aliases, the names `--model` takes) and the chooser's pure
// rules: its rows, search ranking, the remembered pick and the recent picks.
// The helper never builds or rewrites a name: what a row says is what
// `chi send --new --model` gets. `ChiHelper --model-pick` is the build
// spec's seam (stdin: the payload).
import Foundation

/// `chi models --format json`; printed on exit 1 too (no host listed: the
/// default alone).
struct ModelList: Decodable, Equatable {
  struct Model: Decodable, Equatable {
    let name: String
    let host: String
    let id: String
    /// An alias of the same name takes it elsewhere: not offered.
    let shadowedBy: String?
  }

  struct Alias: Decodable, Equatable {
    let name: String
    let ref: String
    let host: String?
  }

  let `default`: String?
  let defaultTyped: String?
  let defaultHost: String?
  let models: [Model]
  let aliases: [Alias]?
  let warnings: [String]?

  static func decode(_ data: Data) -> ModelList? {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(ModelList.self, from: data)
  }

  /// "default (small → box:gemma)" style: the default as the row shows it.
  var defaultLabel: String? {
    guard let name = `default` else { return nil }
    if let typed = defaultTyped, !typed.isEmpty { return "\(typed) → \(name)" }
    return name
  }
}

/// One line of the chooser. +name+ is what `--model` gets (the default row's
/// is the default's name, for show: picking it sends no `--model`).
struct ModelRow: Equatable {
  enum Kind: String { case standard = "default", listed, alias, typed }

  let kind: Kind
  let name: String
  /// The host that listed it ("" when unknown: a recent pick before the list).
  let host: String
  /// What the search looks at besides the host: the id, an alias's name
  /// and target, a typed name.
  let id: String
  let label: String
}

enum ModelPick {
  static let pickKey = "newSessionModel"
  static let recentKey = "recentModels"
  static let maxRecent = 5
  /// ⌘1…⌘9.
  static let maxRows = 9

  static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

  /// Every name the list offers, default host first, an alias after its
  /// host's ids; the default itself left out (it is the Default row).
  static func rows(_ list: ModelList) -> [ModelRow] {
    let defaultHost = list.defaultHost ?? ""
    let listed = list.models.filter { $0.shadowedBy == nil }
    var hosts: [String] = []
    for host in listed.map(\.host) + (list.aliases ?? []).compactMap(\.host) where !hosts.contains(host) {
      hosts.append(host)
    }
    hosts = hosts.filter { $0 == defaultHost } + hosts.filter { $0 != defaultHost }
    var rows: [ModelRow] = []
    for host in hosts {
      for model in listed where model.host == host {
        rows.append(ModelRow(kind: .listed, name: model.name, host: host, id: model.id,
                             label: host == defaultHost ? model.id : "\(host) · \(model.id)"))
      }
      for alias in list.aliases ?? [] where alias.host == host {
        rows.append(ModelRow(kind: .alias, name: alias.name, host: host, id: "\(alias.name) \(alias.ref)",
                             label: "\(alias.name) → \(alias.ref)"))
      }
    }
    for alias in list.aliases ?? [] where alias.host == nil {
      rows.append(ModelRow(kind: .alias, name: alias.name, host: "", id: "\(alias.name) \(alias.ref)",
                           label: "\(alias.name) → \(alias.ref)"))
    }
    guard let standard = list.default else { return rows }
    return rows.filter { !same($0.name, standard) }
  }

  /// The chooser's rows, at most maxRows: Default first; with no query
  /// the recent picks still offered (as they are while the list loads),
  /// then the list; with one, the ranked matches and, when no row is named
  /// exactly that, the typed name ("not listed").
  static func chooserRows(list: ModelList?, fallbackDefault: String?, recents: [String], query: String) -> [ModelRow] {
    let standardName = list?.default ?? fallbackDefault ?? ""
    let standard = ModelRow(kind: .standard, name: standardName, host: list?.defaultHost ?? "", id: standardName,
                            label: standardName.isEmpty ? "Default" : "Default (\(list?.defaultLabel ?? standardName))")
    let all = list.map(rows) ?? []
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var out: [ModelRow] = [standard]
    if text.isEmpty {
      for name in recents where !(list != nil && same(name, standardName)) {
        if let row = all.first(where: { same($0.name, name) }) {
          out.append(row)
        } else if list == nil {
          out.append(ModelRow(kind: .listed, name: name, host: "", id: name, label: name))
        }
      }
      for row in all where !out.contains(where: { same($0.name, row.name) }) { out.append(row) }
      return Array(out.prefix(maxRows))
    }
    let exact = all.contains { same($0.name, text) } || same(text, standardName)
    let room = maxRows - 1 - (exact ? 0 : 1)
    out += match(all, query: text).prefix(room)
    if !exact {
      out.append(ModelRow(kind: .typed, name: text, host: "", id: text, label: "\(text) — not listed"))
    }
    return out
  }

  /// Rows matching every word of +query+ on the host or the id, ranked
  /// like the web's picker: substring-only rows first (at a segment start
  /// cheaper), then subsequences of 3+ characters by their gaps, then the
  /// shorter id, then list order.
  static func match(_ rows: [ModelRow], query: String) -> [ModelRow] {
    let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    guard !words.isEmpty else { return [] }
    var found: [(row: ModelRow, index: Int, sub: Bool, cost: Int)] = []
    for (index, row) in rows.enumerated() {
      let host = Array(row.host.lowercased()), id = Array(row.id.lowercased())
      var sub = true, cost = 0, ok = true
      for word in words {
        let w = Array(word)
        let onId = matchWord(w, id), onHost = matchWord(w, host)
        guard let pick = better(onHost, than: onId) ? onHost : onId else { ok = false; break }
        sub = sub && pick.sub
        cost += pick.cost
      }
      if ok { found.append((row, index, sub, cost)) }
    }
    found.sort { a, b in
      if a.sub != b.sub { return a.sub }
      if a.cost != b.cost { return a.cost < b.cost }
      if a.row.id.count != b.row.id.count { return a.row.id.count < b.row.id.count }
      return a.index < b.index
    }
    return found.map(\.row)
  }

  private static let separators = Set("/-:._ ")

  private static func matchWord(_ word: [Character], _ text: [Character]) -> (sub: Bool, cost: Int)? {
    guard !word.isEmpty, word.count <= text.count else { return nil }
    var best: (sub: Bool, cost: Int)?
    for i in 0...(text.count - word.count) where Array(text[i..<(i + word.count)]) == word {
      let cost = i == 0 || separators.contains(text[i - 1]) ? 0 : 2
      if best == nil || cost < best!.cost { best = (true, cost) }
      if cost == 0 { break }
    }
    if best != nil || word.count < 3 { return best }
    guard var at = text.firstIndex(of: word[0]) else { return nil }
    var gaps = 0
    for k in 1..<word.count {
      guard let i = text[(at + 1)...].firstIndex(of: word[k]) else { return nil }
      gaps += i - at - 1
      at = i
    }
    return (false, 10 + gaps)
  }

  private static func better(_ a: (sub: Bool, cost: Int)?, than b: (sub: Bool, cost: Int)?) -> Bool {
    guard let a else { return false }
    guard let b else { return true }
    return (a.sub && !b.sub) || (a.sub == b.sub && a.cost < b.cost)
  }

  /// The remembered pick for this open: kept while the list loads, and
  /// once it is in, only when offered (as the list spells it) or when no
  /// host listed anything (no way to tell); else the default, with a note.
  static func keep(_ stored: String?, in list: ModelList?) -> (pick: String?, note: String?) {
    guard let stored = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty else { return (nil, nil) }
    guard let list else { return (stored, nil) }
    if let standard = list.default, same(standard, stored) { return (nil, nil) }
    if let row = rows(list).first(where: { same($0.name, stored) }) { return (row.name, nil) }
    if list.models.isEmpty { return (stored, nil) }
    return (nil, "\(stored) isn't listed any more; using the default")
  }

  /// The recent picks after +name+: it first, no other copy (any case).
  static func pushRecent(_ list: [String], _ name: String) -> [String] {
    Array(([name] + list.filter { !same($0, name) }).prefix(maxRecent))
  }
}

/// `ChiHelper --model-pick [--query Q] [--recent NAME]... [--stored NAME]
/// [--push NAME]`: the payload on stdin, the chooser as JSON on stdout
/// (rows, the kept pick and its note, the recents after --push). Exit 1
/// when stdin isn't a payload.
func modelPickCommand(_ args: [String]) -> Int32 {
  var args = args
  var query = "", recents: [String] = [], stored: String?, push: String?
  while !args.isEmpty {
    let arg = args.removeFirst()
    switch arg {
    case "--query" where !args.isEmpty: query = args.removeFirst()
    case "--recent" where !args.isEmpty: recents.append(args.removeFirst())
    case "--stored" where !args.isEmpty: stored = args.removeFirst()
    case "--push" where !args.isEmpty: push = args.removeFirst()
    default:
      FileHandle.standardError.write("usage: ChiHelper --model-pick [--query Q] [--recent NAME]... [--stored NAME] [--push NAME]\n".data(using: .utf8)!)
      return 2
    }
  }
  guard let list = ModelList.decode(FileHandle.standardInput.readDataToEndOfFile()) else {
    FileHandle.standardError.write("not a chi models payload\n".data(using: .utf8)!)
    return 1
  }
  let rows = ModelPick.chooserRows(list: list, fallbackDefault: nil, recents: recents, query: query)
  let kept = ModelPick.keep(stored, in: list)
  var out: [String: Any] = [
    "rows": rows.map { ["kind": $0.kind.rawValue, "name": $0.name, "label": $0.label] },
    "pick": kept.pick ?? NSNull(), "note": kept.note ?? NSNull(), "warnings": list.warnings ?? [],
  ]
  if let push { out["recent"] = ModelPick.pushRecent(recents, push) }
  let data = try! JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
  print(String(decoding: data, as: UTF8.self))
  return 0
}
