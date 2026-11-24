# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "fake_executables"

# A fake `chi` for the peer bundles' scripts/pair: `chi peer pair NAME ID
# [--address ADDR] [--from TEXT]`, every call logged with the CHI_REMOTE it
# saw. It boots no Ruby, so the script's variants (refusals, remote routing,
# odd cwds) cost a shell each; each pair spec keeps a real chi for the
# mechanism.
#
# A `--remote NAME` / `--remote=NAME` word is logged, not obeyed.
# FAKE_CHI_FAIL in the environment makes every call print it on stderr and
# exit 1 (chi's refusal, passed through).
class FakeChiPeer
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
    [ "${1:-} ${2:-}" = "peer pair" ] || { echo "fake chi: peer pair only: $*" >&2; exit 64; }
    name=$3 id=$4
    shift 4
    address= from=
    while [ $# -gt 0 ]; do
      case $1 in --address) address=$2; shift 2 ;; --from) from=$2; shift 2 ;; *) shift ;; esac
    done
    printf '%s\n%s\n%s\n' "$id" "$address" "$from" > "$d/pairs/$name"
    printf '%s  paired with %s\n' "$id" "$name"
  SH

  attr_reader :path

  # Writes the fake as +bin+/+name+, its state beside it.
  def initialize(bin, name = "fake-chi")
    @dir = File.join(bin, "#{name}.d")
    FileUtils.mkdir_p(File.join(@dir, "pairs"))
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

  # The last pairing of peer +name+: { id:, address:, from: } (address nil:
  # answers only), or nil.
  def pairing(name)
    file = File.join(@dir, "pairs", name)
    return unless File.exist?(file)

    id, address, from = File.read(file).lines(chomp: true)
    { id: id, address: address.to_s.empty? ? nil : address, from: from }
  end
end
