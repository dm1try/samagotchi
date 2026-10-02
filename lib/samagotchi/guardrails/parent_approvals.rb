# frozen_string_literal: true

require_relative "../config"
require_relative "approval"

module Samagotchi
  module Guardrails
    # What a parent agent may allow on an approval (guardrails.parent_approvals,
    # config.yml only): off, a deny only; once, "Allow once" too, never a
    # wider scope. `chi answer` checks it before it posts; the worker checks
    # it again for an answer marked as chi answer's (CLIENT_ID), with its own
    # config. A convention for an honest but eager parent, not a security
    # boundary: any local process can post to the Bridge, with or without
    # the marker.
    #
    # An option allows when Approval.settle would allow it: its index is
    # below the approval's scopes. The scope is read by index, never by
    # label. When the scopes are missing or don't fit the options, it fails
    # closed: only a last option labelled Deny denies.
    module ParentApprovals
      KEY = "guardrails.parent_approvals"
      # The client id chi answer posts its answers with.
      CLIENT_ID = "cli:answer"

      module_function

      # This process's setting: "once" or "off" (anything else is off).
      def setting
        Config.get(KEY).to_s == "once" ? "once" : "off"
      end

      # Why a parent may not give this answer, or nil.
      # @param pending [Hash] the pending question (symbol or string keys)
      # @param indices [Array<Integer, nil>] the selected options' places
      # @param setting [String, nil] "off" or "once"
      # @return [Symbol, nil] :off (no allow at all), :once_only, or nil
      def refusal(pending, indices, setting:)
        return nil unless approval?(pending)

        scopes = scopes(pending)
        allows = Array(indices).reject { |index| deny?(pending, scopes, index) }
        return nil if allows.empty?
        return :off unless setting.to_s == "once"
        return nil if scopes && allows.all? { |index| index.is_a?(Integer) && index >= 0 && scopes[index] == "once" }

        :once_only
      end

      # The refusal as a line for the parent.
      # @param reason [Symbol] what #refusal returned
      def message(reason, session_id)
        how = "approve it in the web or chi --attach #{session_id}; deny it with --option Deny --text WHY"
        return "allowing a tool call is up to the user: #{how}" if reason == :off

        "only Allow once (#{KEY}: once) can be given here: #{how}"
      end

      # An approval: its kind says so, or it carries approval facts.
      def approval?(pending)
        fetch(pending, :kind).to_s == Approval::KIND || !fetch(pending, :approval).nil?
      end

      # The offered scopes, in option order, or nil when they are missing,
      # empty, not strings, or leave no option after them for Deny.
      def scopes(pending)
        facts = fetch(pending, :approval)
        scopes = facts.is_a?(Hash) ? fetch(facts, :scopes) : nil
        return nil unless scopes.is_a?(Array) && !scopes.empty? && scopes.all?(String)
        return nil unless scopes.size < options(pending).size

        scopes
      end

      def deny?(pending, scopes, index)
        return false unless index.is_a?(Integer) && index >= 0

        options = options(pending)
        return index >= scopes.size && index < options.size if scopes

        index == options.size - 1 && options[index].to_s == Approval::DENY
      end

      def options(pending) = Array(fetch(pending, :options))

      def fetch(hash, key)
        return nil unless hash.is_a?(Hash)

        hash.key?(key) ? hash[key] : hash[key.to_s]
      end
    end
  end
end
