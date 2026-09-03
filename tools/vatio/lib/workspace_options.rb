# frozen_string_literal: true

module VatioWorkspaceOptions
  module_function

  def parse_flag!(argv)
    workspace = nil
    i = 0
    while i < argv.length
      token = argv[i]
      if token == "--workspace" && argv[i + 1]
        workspace = argv.delete_at(i + 1).to_s.strip.downcase.presence
        argv.delete_at(i)
      elsif token.start_with?("--workspace=")
        workspace = argv.delete_at(i).split("=", 2)[1].to_s.strip.downcase.presence
      else
        i += 1
      end
    end
    workspace
  end
end
