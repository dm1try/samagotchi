# frozen_string_literal: true

require "tmpdir"
require "samagotchi/guardrails/shell_paths"

# Whether a shell command names a path in some dirs (shell-touches-chi's
# touches: chi_dirs): resolved paths, the text for what can't be resolved.
RSpec.describe Samagotchi::Guardrails::ShellPaths do
  let(:root) { File.realpath(Dir.mktmpdir("shell-paths")) }
  let(:home) { File.join(root, "home") }
  let(:config) { File.join(home, ".config", "samagotchi") }
  let(:repo) { File.join(root, "repo") }
  let(:tmp) { File.join(root, "tmp") }
  let(:text) { %r{\.config/samagotchi|samagotchi/config\.yml|samagotchi/hooks|\.git/hooks} }

  before { [config, repo, tmp, File.join(home, "link-parent")].each { |d| FileUtils.mkdir_p(d) } }
  after { FileUtils.rm_rf(root) }

  def touches?(command, env: {}, cwd: repo)
    described_class.touches?(command, dirs: [config, File.join(repo, ".git", "hooks")], text: text, cwd: cwd,
                                      home: home, env: env, tmp_roots: [tmp])
  end

  touching = [
    "echo x >> ~/.config/samagotchi/config.yml", "echo x >>~/.config/samagotchi/config.yml",
    "cp a $HOME/.config/samagotchi/hooks/x.rb", "cp a ${HOME}/.config/samagotchi/x",
    "cd ~/.config && echo x > samagotchi/config.yml", "cd ~/.config/samagotchi; rm config.yml",
    "(cd ~/.config/samagotchi && touch x)", "pushd ~/.config/samagotchi && touch x && popd",
    "cp hook .git/hooks/pre-commit", "cd sub && cp hook ../.git/hooks/x", "tee ~/.config/samagotchi/x",
    "install --target-directory=~/.config/samagotchi x", "X=~/.config/samagotchi/a make",
    "cp hook ../other/.git/hooks/pre-commit",
    # can't be resolved: the text decides
    "sh -c 'echo x >> ~/.config/samagotchi/config.yml'", "ruby -e 'File.write(\"samagotchi/config.yml\", 1)'",
    "cp a $SOMEWHERE/.config/samagotchi/x", "cp a ~/.config/samagotchi/*.yml", "cd $X && echo > samagotchi/hooks/a",
    "cat > \"$(echo ~/.config/samagotchi)/config.yml\""
  ]

  not_touching = [
    "echo x > /tmp/pp/config/samagotchi/config.yml", "rg samagotchi/hooks lib", "echo x > lib/samagotchi/hooks/x.rb",
    "cp a ~/.configs/samagotchi", "cp a ~/projects/x", "cd ~/.config && ls", "echo samagotchi",
    "cd $X && echo > other.txt", "ls -la", "make -C sub"
  ]

  touching.each do |command|
    it "touches: #{command.inspect}" do
      expect(touches?(command)).to be(true)
    end
  end

  not_touching.each do |command|
    it "doesn't touch: #{command.inspect}" do
      expect(touches?(command)).to be(false)
    end
  end

  it "expands $XDG_CONFIG_HOME from the environment, ~/.config when it is unset" do
    expect(touches?("echo x > $XDG_CONFIG_HOME/samagotchi/config.yml")).to be(true)
    elsewhere = File.join(root, "xdg")
    expect(touches?("echo x > $XDG_CONFIG_HOME/samagotchi/config.yml", env: { "XDG_CONFIG_HOME" => elsewhere })).to be(false)
    expect(touches?("echo x > ${XDG_CONFIG_HOME}/samagotchi/a", env: { "XDG_CONFIG_HOME" => File.join(home, ".config") })).to be(true)
  end

  it "resolves symlinks, so a link to chi's config dir counts and a tmp dir doesn't" do
    File.symlink(config, File.join(repo, "cfg"))
    expect(touches?("echo x > cfg/config.yml")).to be(true)
    expect(touches?("cp hook #{tmp}/r/.git/hooks/x")).to be(false)
  end

  it "keeps a chi dir that is itself under a tmp dir (a sandboxed config)" do
    sandboxed = File.join(tmp, "xdg", "samagotchi")
    FileUtils.mkdir_p(sandboxed)
    expect(described_class.touches?("echo x > #{sandboxed}/config.yml", dirs: [sandboxed], text: text, cwd: repo,
                                                                         home: home, env: {}, tmp_roots: [tmp])).to be(true)
  end

  it "reads relative words against an unknown cwd as text" do
    expect(touches?("echo > samagotchi/config.yml", cwd: nil)).to be(true)
    expect(touches?("echo > other.yml", cwd: nil)).to be(false)
  end
end
