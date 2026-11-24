# frozen_string_literal: true

require_relative "../pages"
require_relative "../installed_bundles"

module Samagotchi
  module Pages
    # The pages installed bundles ship: a manifest's pages: names scripts/
    # files, each NAME.rb the page NAME (docs/pages.md, "Pages from a
    # bundle"). Read from the install records (InstalledBundles), so chi web
    # answers without loading a plugin. The first bundle by name wins a page
    # name; a bundle chi won't use (its record doesn't read, or it needs a
    # newer chi) ships none. The user's own NAME.rb shadows a bundle's page
    # (Pages.script_path), which is how a page is made one's own: copy the
    # bundle's script there and change it.
    #
    # Loaded only when no NAME.rb of the user's is there (Pages autoloads
    # it): installed_bundles.rb reaches the config, which a user's page run
    # never loads.
    module Bundled
      # One bundle page: its name, the bundle, the scripts/ file and its
      # installed path.
      Page = Data.define(:name, :bundle, :file, :path) do
        # Why chi won't run it (its file is missing, unrecorded, or not as
        # installed: InstalledBundles::Dir#file_refusal's words), nil when it may.
        # @return [String, nil]
        def refusal
          recorded = InstalledBundles.standing(bundle)&.record&.scripts&.fetch(file, nil)
          InstalledBundles::Dir.new(name: bundle).file_refusal(:scripts, file, recorded)&.text
        end
      end

      module_function

      # @return [Array<Page>] by name
      def all
        taken = {}
        InstalledBundles.standings do |standing|
          next unless standing.usable?

          scripts_dir = InstalledBundles::Dir.new(name: standing.name).scripts_dir
          standing.record.manifest.pages.each do |file|
            name = file.delete_suffix(".rb")
            taken[name] ||= Page.new(name: name, bundle: standing.name, file: file, path: File.join(scripts_dir, file))
          end
        end
        taken.values.sort_by(&:name)
      end

      # @return [Page, nil]
      def find(name) = all.find { |page| page.name == name }
    end
  end
end
