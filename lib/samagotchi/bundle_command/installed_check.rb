# frozen_string_literal: true

require "json"
require "stringio"
require "tmpdir"
require_relative "../config"
require_relative "../memory_bundle/installed_copy"
require_relative "../memory_bundle/shipped_update"
require_relative "../process_group"
require_relative "check"

module Samagotchi
  class BundleCommand
    # `chi update`'s look at a bundle chi didn't ship: Check (installed: true)
    # on its InstalledCopy, under the chi running now. It runs the bundle's
    # code, as every session does, so in a child of its own: a plugin that
    # exits, hangs, prints or patches something is that bundle's finding and
    # reaches neither the update nor the next bundle.
    module InstalledCheck
      # Seconds a bundle's check may take; a load takes well under one.
      TIMEOUT = 30
      # level: "warn" or "error"; text: Check::Finding's line, on one line.
      Found = Data.define(:level, :text)

      module_function

      # @param bundle [MemoryBundle::InstalledBundle]
      # @return [Array<Found>] its warnings and errors; never raises for the bundle
      def run(bundle)
        $stdout.flush
        $stderr.flush
        Dir.mktmpdir("chi-installed-check-") { |tmp| in_child(bundle, File.join(tmp, "answer.json")) }
      rescue SystemCallError, IOError, JSON::ParserError => e
        # JSON: a child that died mid-write (a full disk) left half an answer.
        [died("#{e.class}: #{e.message}")]
      end

      def in_child(bundle, answer)
        pid = Process.fork do
          Process.setpgid(0, 0)
          [STDIN, STDOUT, STDERR].zip(%w[r w w]) { |io, mode| io.reopen(File::NULL, mode) }
          File.write(answer, JSON.generate(answer_of(bundle)))
          Process.exit!(0)
        rescue Exception => e # rubocop:disable Lint/RescueException -- a plugin's exit too: the bundle's row
          File.write(answer, JSON.generate([{ level: "error", text: check_line("the check died: #{e.class}: #{e.message}") }]))
          Process.exit!(1)
        end
        waiter = Process.detach(pid)
        unless waiter.join(TIMEOUT)
          ProcessGroup.signal(pid, "KILL", leader: true)
          waiter.join
          return [died("no answer in #{TIMEOUT} s", prefix: false)]
        end
        return [died("exit status #{waiter.value.exitstatus.inspect}")] unless File.file?(answer)

        JSON.parse(File.read(answer)).map { |row| Found.new(level: row["level"], text: row["text"].gsub(/\s*\n\s*/, " ").strip) }
      end
      private_class_method :in_child

      # What the child sends: an edited file, which the copy's own shas can't
      # tell, and Check's warnings and errors, naming the installed bundle's
      # folder rather than the copy's.
      def answer_of(bundle)
        edited = MemoryBundle::ShippedUpdate.edited_executables(bundle.name, bundle).map do |file|
          Check::Finding.new(level: :warn, code: :edited, file: file, line: nil, fix: "chi bundle upgrade #{bundle.name}, or reinstall it",
                             message: "changed since it was installed, so chi doesn't load it")
        end
        edited = edited.map { |finding| { level: finding.level, text: finding.to_s } }
        installed_dir = MemoryBundle::Provenance.new(name: bundle.name).bundle_dir
        edited + MemoryBundle::InstalledCopy.with(bundle) do |dir|
          check = Check.new(dir, settings: ConfigFile.bundle_settings.fetch(bundle.name, {}), installed: true, stdout: StringIO.new)
          check.run
          check.findings.reject { |finding| finding.level == :info }
               .map { |finding| { level: finding.level, text: finding.to_s.gsub(dir, installed_dir) } }
        end
      end
      private_class_method :answer_of

      def died(why, prefix: true) = Found.new(level: "error", text: check_line(prefix ? "the check died: #{why}" : why))
      private_class_method :died

      def check_line(message) = Check::Finding.new(level: :error, code: :check, file: "manifest.json", line: nil, message: message, fix: nil).to_s
      private_class_method :check_line
    end
  end
end
