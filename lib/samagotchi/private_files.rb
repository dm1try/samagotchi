# frozen_string_literal: true

module Samagotchi
  module Web
    # chi web's private state folders (web-grants/, web-push/): a folder
    # only this user can enter (0700) with files only this user can read
    # (0600). chi web refuses to start on one others can read (Server.launch);
    # the reason words say what the folder holds.
    module PrivateFiles
      module_function

      # Refuses +dir+ or any of +files+ when others can read it or it isn't
      # this user's. Only these: the state dir above them is often 0755, and
      # that is fine. A folder or file not made yet passes (it is made 0700 /
      # 0600).
      # @param holds [String] what is in them ("the participants' grants")
      # @param error [Class] the exception to raise
      def check!(dir, files, holds:, error:)
        [dir, *files].each do |target|
          stat = File.stat(target)
          next if stat.mode.nobits?(0o077) && stat.uid == Process.uid

          raise error, "#{target} can be read by other users: chmod 700 #{dir} and 600 #{files.join(" ")} " \
                       "(it holds #{holds})"
        rescue Errno::ENOENT
          next
        end
      end
    end
  end
end
