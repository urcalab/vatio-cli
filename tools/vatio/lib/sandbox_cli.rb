# frozen_string_literal: true

require "optparse"
require "json"
require "fileutils"

require_relative "cli_config"
require_relative "identity_hints"
require_relative "sandbox_client"

# Preview chat CLI for `vatio chat …`.
# Always talks to preview (`/api/v1/:ws/chats`, environment: "preview"). Live is for public visitors only.
class VatioSandboxCLI
  include VatioSandboxSupport

  STATE_FILE = ".vatio-sandbox.json"
  SUBCOMMANDS = %w[transcript debug reset help].freeze

  def initialize(config:)
    @config = config
    root = (@config.workspace_root || Pathname(Dir.pwd)).to_s
    @root = root
    @state_file = File.join(@root, STATE_FILE)
  end

  def run(argv)
    warn_legacy_as! if @config.legacy_as_removed

    options = default_options
    argv = argv.dup

    parser = OptionParser.new do |opts|
      opts.banner = "Usage: vatio chat [MESSAGE] [options] (preview)"

      opts.on("--timeout SECONDS", Integer, "Wait timeout in seconds") { |value| options[:timeout] = value }
      opts.on("--last N", Integer, "Number of messages to print") { |value| options[:last] = value }
      opts.on("--channel CHANNEL", "Simulate ingress channel (cli|web|whatsapp|email|instagram)") { |value| options[:channel] = value }
      opts.on("--from IDENTITY", "External sender identity (phone, email, or ref)") { |value| options[:from] = value }
      opts.on("--sandbox-url URL", "Override VATIO_SANDBOX_URL") { |value| options[:sandbox_url] = value }
      opts.on("--token TOKEN", "Override VATIO_TOKEN") { |value| options[:token] = value }
      opts.on("--workspace SLUG", "Workspace slug") { |value| options[:workspace] = value }
      opts.on("-h", "--help", "Show help") do
        print_help(parser)
        exit 0
      end
    end

    begin
      parser.parse!(argv)
    rescue OptionParser::InvalidOption => e
      if e.args.any? { |a| a.start_with?("--as") }
        abort "`--as` was removed. Use --channel and --from to simulate ingress without authentication."
      end
      raise
    end

    command = argv.first
    if SUBCOMMANDS.include?(command)
      argv.shift
      case command
      when "transcript" then transcript(options)
      when "debug" then debug_conversation(options)
      when "reset" then reset_session(options)
      when "help" then print_help(parser)
      end
      return
    end

    message = argv.join(" ").strip
    if blank?(message)
      print_help(parser)
      return
    end

    converse(options.merge(message: message))
  end

  private

  def default_options
    {
      timeout: 120,
      last: 10
    }
  end

  def print_help(parser = nil)
    puts parser if parser
    puts <<~HELP

      Usage:
        vatio chat "mensaje" [--channel CHANNEL] [--from IDENTITY] [--timeout N]
        vatio chat transcript [--last N]
        vatio chat debug [--last N]
        vatio chat reset [--channel CHANNEL] [--from IDENTITY]
        vatio chat destroy CHAT_ID [--workspace SLUG]

      Simulate ingress (never delivers WhatsApp/email; never creates a session):
        --channel cli|web|whatsapp|email|instagram
        --from PHONE_OR_EMAIL_OR_REF
        vatio config set channel whatsapp
        vatio config set from +56912345678

      Note: CLI chats always use the preview deployment (never live).
      transcript/debug reuse the current .vatio-sandbox.json chat when channel/from
      are unchanged. Changing channel or from opens a new session.
    HELP
  end

  def client(options)
    sandbox_url = resolve_sandbox_url(options)
    token = presence(options[:token]) || @config.resolve_token
    raise "VATIO_SANDBOX_URL is required (env, --sandbox-url, or base_url + workspace via `vatio config`)" if blank?(sandbox_url)
    raise "VATIO_TOKEN is required (env or `vatio config set token …`)" if blank?(token)

    VatioSandboxClient.new(sandbox_url: sandbox_url, token: token)
  end

  def resolve_sandbox_url(options)
    @config.resolve_sandbox_url(explicit: options[:sandbox_url], workspace: options[:workspace])
  end

  def load_state
    return {} unless File.exist?(@state_file)

    data = JSON.parse(File.read(@state_file))
    return {} unless data.is_a?(Hash)

    # Legacy impersonation state must never become channel evidence.
    if data.key?("as")
      FileUtils.rm_f(@state_file)
      return {}
    end

    data
  rescue JSON::ParserError
    {}
  end

  def save_state(state)
    File.write(@state_file, JSON.pretty_generate(state))
  end

  def resolve_ingress(options, allow_state_fallback: false)
    state = load_state
    channel_explicit = options.key?(:channel)
    from_explicit = options.key?(:from)

    channel =
      if channel_explicit
        options[:channel]
      elsif allow_state_fallback && present?(state["channel"])
        state["channel"]
      else
        @config.resolve_channel
      end

    from =
      if from_explicit
        options[:from]
      elsif allow_state_fallback && state.key?("from")
        state["from"]
      else
        @config.resolve_from
      end

    simulation = VatioIdentityHints.resolve_simulation(
      channel: channel,
      from: from,
      token_prefix: "cli",
      session_id: "local"
    )
    if simulation[:error]
      abort simulation[:message]
    end

    {
      channel: simulation[:channel],
      from: simulation[:from_label],
      from_raw: from
    }
  end

  def ensure_chat!(client, options)
    state = load_state
    sandbox_url = resolve_sandbox_url(options)
    ingress = resolve_ingress(options, allow_state_fallback: false)

    if state["sandbox_url"] == sandbox_url &&
        present?(state["chat_id"]) &&
        state["channel"].to_s == ingress[:channel].to_s &&
        state["from"].to_s == ingress[:from].to_s
      return state["chat_id"].to_i
    end

    open_chat!(client, sandbox_url: sandbox_url, ingress: ingress).fetch("chat_id").to_i
  end

  # transcript/debug must not open a new chat when channel/from overrides are omitted.
  def ensure_existing_chat!(client, options)
    state = load_state
    sandbox_url = resolve_sandbox_url(options)

    if present?(state["chat_id"]) && state["sandbox_url"] == sandbox_url
      if options.key?(:channel) || options.key?(:from)
        ingress = resolve_ingress(options, allow_state_fallback: false)
        if state["channel"].to_s != ingress[:channel].to_s || state["from"].to_s != ingress[:from].to_s
          return open_chat!(client, sandbox_url: sandbox_url, ingress: ingress).fetch("chat_id").to_i
        end
      end
      return state["chat_id"].to_i
    end

    ensure_chat!(client, options)
  end

  def create_or_reset_chat!(client, options, chat_id: nil)
    open_chat!(
      client,
      sandbox_url: resolve_sandbox_url(options),
      ingress: resolve_ingress(options, allow_state_fallback: true),
      chat_id: chat_id
    )
  end

  def open_chat!(client, sandbox_url:, ingress:, chat_id: nil)
    payload = if present?(chat_id)
      client.reset_chat_for(
        chat_id: chat_id,
        channel: ingress[:channel],
        from: ingress[:from]
      )
    else
      client.create_chat(
        channel: ingress[:channel],
        from: ingress[:from]
      )
    end

    save_chat_state!(
      sandbox_url: sandbox_url,
      chat_id: payload["chat_id"],
      channel: ingress[:channel],
      from: ingress[:from]
    )
    print_simulation!(ingress, payload)
    payload
  end

  def save_chat_state!(sandbox_url:, chat_id:, channel:, from:)
    state = load_state
    state["sandbox_url"] = sandbox_url
    state["track"] = "preview"
    state["chat_id"] = chat_id
    state["channel"] = channel
    state["from"] = from
    state.delete("as")
    state.delete("last_user_message_id")
    save_state(state)
  end

  def print_simulation!(ingress, payload)
    from_part = present?(ingress[:from]) ? " from=#{ingress[:from]}" : ""
    puts "Simulating channel=#{ingress[:channel]}#{from_part}"
    channel = payload["channel"]
    puts "  chat.channel=#{channel}" if present?(channel) && channel.to_s != ingress[:channel].to_s
  end

  def warn_legacy_as!
    warn "Removed legacy config key `as`. Set `channel` and `from` instead " \
         "(example: vatio config set channel whatsapp && vatio config set from +56912345678)."
  end

  def converse(options)
    cli = client(options)
    chat_id = ensure_chat!(cli, options)
    payload = cli.send_message(chat_id: chat_id, content: options[:message])
    user_message_id = payload["user_message_id"]

    state = load_state
    state["last_user_message_id"] = user_message_id
    save_state(state)

    assistant = cli.wait_for_assistant(
      chat_id: chat_id,
      after_message_id: user_message_id,
      timeout: options[:timeout],
      view: "visitor"
    )

    puts format_visitor_message(assistant)
  end

  def transcript(options)
    cli = client(options)
    chat_id = ensure_existing_chat!(cli, options)
    target = options[:last]
    fetch_limit = [ target * 6, 200 ].min
    payload = cli.messages(chat_id, view: "visitor", limit: fetch_limit)
    visitor_messages(payload.fetch("data", [])).last(target).each do |message|
      puts format_visitor_message(message)
    end
  end

  def debug_conversation(options)
    cli = client(options)
    chat_id = ensure_existing_chat!(cli, options)

    puts "## Chat status (developer)"
    status = cli.show_chat(chat_id, view: "developer")
    puts JSON.pretty_generate(status)

    puts
    puts "## Transcript (developer/debug, last #{options[:last]})"
    payload = cli.messages(chat_id, view: "developer", limit: options[:last])
    payload.fetch("data", []).each do |message|
      puts format_debug_message(message)
    end
  end

  def reset_session(options)
    cli = client(options)
    state = load_state

    payload = if present?(state["chat_id"])
      create_or_reset_chat!(cli, options, chat_id: state["chat_id"])
    else
      create_or_reset_chat!(cli, options)
    end

    puts "Reset preview chat #{payload["chat_id"]}"
  end

  def visitor_messages(messages)
    Array(messages).select { |message| visitor_visible_message?(message) }
  end

  def visitor_visible_message?(message)
    role = message["role"].to_s
    return false unless %w[user assistant].include?(role)
    return false if message["discarded"]

    present?(message["content"].to_s.strip)
  end

  def format_visitor_message(message)
    role = message["role"].to_s.upcase
    content = message["content"].to_s.strip
    "[#{role}] #{content}"
  end

  def format_debug_message(message)
    role = message["role"].to_s.upcase
    flags = []
    flags << "DISCARDED" if message["discarded"]
    flags << "blank" if message["content_blank"] || blank?(message["content"].to_s.strip)
    flag_suffix = flags.any? ? " (#{flags.join(", ")})" : ""

    lines = [ "[#{role}#{flag_suffix}] #{message["content"]}" ]
    meta = []
    meta << "id=#{message["id"]}" if present?(message["id"])
    meta << "agent=#{message["agent_slug"]}" if present?(message["agent_slug"])
    lines << "  #{meta.join(" ")}" if meta.any?

    Array(message["tool_calls"]).each do |tool_call|
      lines << "  tool: #{tool_call["name"]} args=#{tool_call["arguments"].to_json}"
      result = tool_call["result"]
      next if blank?(result)

      summary = result["message"] || result["content"]
      lines << "    result: #{result["result"].inspect} message=#{summary.inspect}"
    end

    lines.join("\n")
  end
end
