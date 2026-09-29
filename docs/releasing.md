# Releasing

samagotchi is published to rubygems.org as the gem `samagotchi` (command `chi`)
by GitHub Actions when a `v*` tag is pushed. Nothing publishes from a laptop:
there is no API key anywhere, and bundler's `rake release` is removed. An agent
can run the whole release; the user approves the notes before the tag and the
`release` environment after it.

## Versions

- **The gem and the system bundle share one version.** `lib/samagotchi/version.rb`
  and `lib/samagotchi/bundles/system/manifest.yml` are bumped together (a spec
  and `rake release:check` enforce it). The system bundle upgrades itself when
  chi starts.
- **Every other shipped bundle** (btw, guardrails, known-names, loop-guard,
  mcp) has its own semver in its `manifest.yml` and, when it needs a newer chi,
  a `requires_chi:` line. They never upgrade by themselves: users run
  `chi update` (all of them, with the gem) or `chi bundle upgrade NAME`. So:
  - a change to a bundle's files bumps that bundle's `version:`
    (`rake bundles:check` fails otherwise, once there's a tag to compare with);
  - a bundle that uses something new in chi raises its `requires_chi` in the
    same change; `release:bump` never touches `requires_chi`;
  - the release notes say "run `chi update`" and name the bundles whose
    version moved (what changed in each), not per-bundle upgrade steps.
- Pre-1.0: config and commands may change in a minor version (0.2 → 0.3); a
  patch version (0.2.0 → 0.2.1) is fixes only.

## CHANGELOG.md

[Keep a Changelog](https://keepachangelog.com/en/1.1.0/): user-facing lines
under `## [Unreleased]`, grouped as `### Added`, `### Changed`, `### Fixed`
(and `### Removed` / `### Security` when needed). Write them for someone who
uses chi, not for someone who reads the diff: what changed for them, in one
line each. A merge with a user-visible change adds its line; anything missed is
drafted at release time (`rake release:draft_changelog`). Internal refactors,
specs and docs-only changes don't get a line.

`rake release:bump[X.Y.Z]` turns `## [Unreleased]` into `## [X.Y.Z] - date`
under a fresh empty Unreleased, and updates the compare links at the bottom.
The release workflow uses that section, as printed by `rake release:notes[X.Y.Z]`,
as the GitHub release body.

## Tasks

| Task | What it does |
| --- | --- |
| `rake bundles:sha` | Recomputes the sha256 lines of every shipped bundle manifest (`files:`, `hooks:`, `plugin:`). |
| `rake bundles:check` | Sha lines match; a bundle changed since the last `v*` tag has a higher version (skipped, with a note, before the first tag). |
| `rake release:draft_changelog` | A draft Unreleased section from the commit subjects since the last tag, grouped. Stdout only. |
| `rake release:bump[X.Y.Z]` | VERSION, the system manifest, Gemfile.lock, CHANGELOG. No commit. |
| `rake release:check` | Clean tracked tree, VERSION == system bundle, a CHANGELOG section, `bundles:check`, rspec + npm test, `gem build`, then a clean install into a temp GEM_HOME that runs `chi --version`, `chi self` and `chi bundle list` with a temp HOME. Needs the network (gem dependencies). |
| `rake release:notes[X.Y.Z]` | Prints the CHANGELOG section (default: the current VERSION). |

## Runbook

The agent does each step and stops where the user has to say yes.

1. **Start from main, up to date and green.** `git checkout main && git pull`;
   CI on main is green.
2. **Draft the notes.** `bundle exec rake release:draft_changelog`, then edit
   `## [Unreleased]` in CHANGELOG.md into short user-facing lines. End with
   "Update with `chi update`", naming the bundles whose version moved since
   the last tag (`git diff vPREV -- lib/samagotchi/bundles/*/manifest.yml`).
   Pick the version: fixes only → patch, anything else → minor.
3. **The user approves the notes and the version.** Show them the section.
4. **Bump.** `bundle exec rake "release:bump[X.Y.Z]"`, review `git diff`.
5. **Check.** Commit first (the check wants a clean tree), then run it:
   `git commit -am "Release X.Y.Z"` and `bundle exec rake release:check`.
   Fix anything it finds in new commits and run it again.
6. **Push main.** `git push origin main`; wait for CI to go green.
7. **Tag and push the tag.**
   `git tag -a vX.Y.Z -m "samagotchi X.Y.Z" && git push origin vX.Y.Z`
   (push the tag alone; never `--tags`, `--all` or `--mirror`).
8. **The user approves the `release` environment** in the Actions run
   (Review deployments → Approve).
9. **Watch the run.** `gh run watch` (or `gh run list --workflow release.yml`).
   It checks that the tag is `v` + VERSION and on main, builds the gem, pushes
   it with a trusted-publishing token and creates the GitHub release with the
   notes and the .gem attached.
10. **Verify the published gem** in a clean GEM_HOME:
    ```sh
    tmp=$(mktemp -d)
    GEM_HOME=$tmp GEM_PATH=$tmp gem install samagotchi -v X.Y.Z --no-document
    HOME=$tmp/home XDG_CONFIG_HOME=$tmp/home/.config XDG_STATE_HOME=$tmp/home/.local/state \
      GEM_HOME=$tmp GEM_PATH=$tmp $tmp/bin/chi --version    # chi X.Y.Z
    ```
    and `chi self` the same way. Then tell the user; on their machine
    `gem update samagotchi` (and `chi desktop upgrade` if they use the desktop
    helper).

If the run fails before `gem push`, fix it on main, delete the tag
(`git push origin :refs/tags/vX.Y.Z && git tag -d vX.Y.Z`) and tag again. A
version that reached rubygems.org can never be pushed again: fix forward with
the next patch version.

## One-time setup

Done once, before the first release, in one sitting (the pending publisher
expires):

1. **rubygems.org**: an account with MFA on. Profile → Trusted Publishers →
   *Create a pending trusted publisher* (the gem doesn't exist yet):
   gem name `samagotchi`, repository owner `dm1try`, repository name
   `samagotchi`, workflow filename `release.yml`, environment `release`;
   leave *workflow repository* blank. **A pending publisher expires 12 hours
   after it's created**: push the first tag within that window, or create it
   again. After the first push it becomes the gem's trusted publisher for good.
2. **GitHub, Settings → Environments → New environment `release`**: required
   reviewer = the maintainer; deployment branches and tags → selected, the tag
   pattern `v*`.
3. **GitHub, Settings → Rules → Rulesets → New tag ruleset**: target `v*`,
   restrict creations, updates and deletions to the maintainer (and the agent's
   credentials if they push tags), block force pushes.

## Yanking

A broken release is yanked, then fixed forward:

```sh
gem yank samagotchi -v X.Y.Z    # needs a rubygems.org login with MFA (an API key with the yank scope)
```

Yanking hides the version from installs; it can't be pushed again. Mark the
GitHub release as such (`gh release edit vX.Y.Z --prerelease` or edit its
notes: "yanked: …"), add a `### Fixed` line under Unreleased, and release the
next patch version.

## CI on Linux

The suite runs the same on Linux CI as on macOS, with no CI-only skips. A few
things differ there, and a new spec that trips on them fails only on CI:

- `CI` set marks every new session a test run, and `--all`, `list_sessions`
  and friends leave test runs out. A spec that lists sessions makes them with
  `test_run: false`.
- The gems live under `vendor/bundle`: a child `ruby` started with a bare env
  (`unsetenv_others: true`) needs `GEM_HOME`/`GEM_PATH` to find nokogiri.
- Ruby 3.3's zlib raises `Zlib::BufError` when a thread interrupt lands in a
  deflate (ruby/zlib#57, fixed in Ruby 3.4's zlib): build gems in a child
  process, as `spec/gem_contents_spec.rb` does.

To run it locally, use Docker with the Ruby build CI uses
(`ruby-X.Y.Z-ubuntu-24.04-x64.tar.gz` from ruby/ruby-builder's releases) on
`ubuntu:24.04` with `LANG=C.UTF-8`, `zip` and `git`, and run
`CI=1 BUNDLE_PATH=… bundle exec rspec`.
