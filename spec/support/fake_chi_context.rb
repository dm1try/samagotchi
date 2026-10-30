# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "fake_executables"

# A fake `chi` for the peer bundles' scripts/pair: `chi context add|show|
# push|rm|ls` on a folder, every call logged with the CHI_REMOTE it saw. It
# boots no Ruby, so the script's variants (refusals, remote routing, odd
# cwds) cost a shell each; each pair spec keeps a real chi for the mechanism.
#
# It keeps what the script relies on: `add` refuses a name attached already
# (and `show` then finds it), `show` prints the source's why, `rm` drops the
# source and its last push. A `--remote NAME` / `--remote=NAME` word is
# logged, not obeyed. FAKE_CHI_FAIL in the environment makes every call
# print it on stderr and exit 1 (chi's refusal, passed through).
class FakeChiContext
  SEP = "\x1f"

  BODY = <<~'SH'
    d=__DIR__
    { printf '%s' "${CHI_REMOTE-}"; for a do printf '\037%s' "$a"; done; printf '\n'; } >> "$d/calls.log"
    if [ -n "${FAKE_CHI_FAIL:-}" ]; then printf '%s\n' "$FAKE_CHI_FAIL" >&2; exit 1; fi
    skip=
    for a do
      shift
      if [ -n "$skip" ]; then skip=; continue; fi
      case $a in --remote) skip=1; continue ;; --remote=*) continue ;; esac
      set -- "$@" "$a"
    done
    [ "${1:-}" = context ] || { echo "fake chi: context only: $*" >&2; exit 64; }
    sub=$2 name=$3
    src="$d/sources/$name"
    case $sub in
      add)
        if [ -e "$src" ]; then echo "Error: $name is attached already" >&2; exit 1; fi
        why= hint=
        shift 3
        while [ $# -gt 0 ]; do
          case $1 in --why) why=$2; shift 2 ;; --hint) hint=$2; shift 2 ;; *) shift ;; esac
        done
        printf '%s\n%s\n' "$why" "$hint" > "$src" ;;
      show) [ -e "$src" ] || exit 1; cat "$src" ;;
      push) cat > "$d/pushed/$name.json" ;;
      rm) rm -f "$src" "$d/pushed/$name.json" ;;
      ls) ls "$d/sources" ;;
      *) echo "fake chi: no context $sub" >&2; exit 64 ;;
    esac
  SH

  attr_reader :path

  # Writes the fake as +bin+/+name+, its state beside it.
  def initialize(bin, name = "fake-chi")
    @dir = File.join(bin, "#{name}.d")
    FileUtils.mkdir_p([File.join(@dir, "sources"), File.join(@dir, "pushed")])
    @path = FakeExecutables.fake_executable(bin, name, BODY.sub("__DIR__", "'#{@dir}'"))
  end

  # Every call so far: [CHI_REMOTE as chi saw it, argv].
  # @return [Array<Array(String, Array<String>)>]
  def calls
    log = File.join(@dir, "calls.log")
    return [] unless File.exist?(log)

    File.readlines(log, chomp: true).map do |line|
      remote, *argv = line.split(SEP, -1)
      [remote, argv]
    end
  end

  # The attached source +name+: { why:, hint: }, or nil.
  def source(name)
    file = File.join(@dir, "sources", name)
    return unless File.exist?(file)

    why, hint = File.read(file).lines(chomp: true)
    { why: why, hint: hint }
  end

  # The last JSON pushed to +name+, parsed strictly (a raw control
  # character in a string is refused, as chi refuses it), or nil.
  def pushed(name)
    file = File.join(@dir, "pushed", "#{name}.json")
    File.exist?(file) ? JSON.parse(File.read(file)) : nil
  end
end
