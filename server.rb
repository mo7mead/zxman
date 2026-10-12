#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================
#  zxman — request catcher
#  A tiny HTTP listener that logs every incoming request and
#  serves static files from ./public.
#
#  - /static/<file>  -> served from ./public  (NOT logged as a hit)
#  - any other path  -> captured, logged, counted
#  - ./public list   -> shown live with copy-ready links
#  - new files       -> detected and flagged automatically
#
#  Needs Ruby 3.0+ and the `webrick` gem:  gem install webrick
#  Run:  ruby server.rb        (use -h for help)
# ============================================================

require 'webrick'
require 'socket'
require 'json'
require 'time'
require 'fileutils'
require 'open3'
require 'base64'
require 'securerandom'
require 'io/console'

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------
module Config
  VERSION   = '1.0.0'
  PORT      = (ENV['PORT'] || 8000).to_i
  ROOT      = __dir__
  PUBLIC    = File.join(ROOT, 'public')
  HITS      = File.join(ROOT, 'hits')
  LOG       = File.join(ROOT, 'requests.log')
  MIN_WIDTH = 64                       # narrowest the box ever gets
  MAX_WIDTH = 150                      # widest, so it stays readable
  STREAM    = 12                       # request lines kept on screen
  BODY_CAP  = 64 * 1024                # max request body bytes recorded
  # Set TUNNEL=0 to disable the automatic public tunnel.
  TUNNEL    = ENV.fetch('TUNNEL', '1') != '0'
  # Set INDEX=1 to let /static browse the directory listing.
  INDEXING  = ENV.fetch('INDEX', '0') == '1'
  # Set KILL_PORT=1 to let the server TERM whatever holds the port.
  KILL_PORT = ENV.fetch('KILL_PORT', '0') == '1'
end

# ------------------------------------------------------------
# Command-line interface: -h / --help and -v / --version.
# Handled before any side effects (dir creation, binding).
# ------------------------------------------------------------
module CLI
  module_function

  def help
    <<~TXT
      zxman #{Config::VERSION} — a tiny HTTP request catcher with a live
      dashboard and an optional public tunnel.

      USAGE
          ruby server.rb [options]
          [ENV=value ...] ruby server.rb

      OPTIONS
          -h, --help       Show this help and exit
          -v, --version    Show the version and exit

      ENVIRONMENT
          PORT=<n>         Port to bind on 0.0.0.0            (default: 8000)
          TUNNEL=0|1       Run the cloudflared public tunnel  (default: 1)
          INDEX=0|1        Allow /static directory listing     (default: 0)
          KILL_PORT=0|1    Terminate a process holding PORT    (default: 0)
          NO_COLOR=<any>   Disable coloured output             (default: off)

      ENDPOINTS
          /static/<file>   Served from ./public  (not logged as a hit)
          <any other>      Captured → requests.log and hits/<ts>-<rand>.json

      EXAMPLES
          ruby server.rb                 # port 8000, tunnel on
          TUNNEL=0 ruby server.rb        # local only, no public URL
          PORT=9000 ruby server.rb       # bind port 9000
          sudo PORT=80 ruby server.rb    # bind the default HTTP port

      Press Ctrl+C to stop. Captured data lands in ./hits and ./requests.log.
    TXT
  end

  def run(argv)
    case argv[0]
    when nil
      # no args: fall through and start the server
    when '-h', '--help'
      puts help
      exit 0
    when '-v', '--version'
      puts "zxman #{Config::VERSION}"
      exit 0
    else
      warn "zxman: unknown option '#{argv[0]}' — try 'ruby server.rb -h'"
      exit 1
    end
  end
end

CLI.run(ARGV)

FileUtils.mkdir_p(Config::PUBLIC)
FileUtils.mkdir_p(Config::HITS)

# ------------------------------------------------------------
# ANSI terminal helpers — 256-colour palette, graceful on dumb
# terminals (NO_COLOR / non-tty disables styling entirely).
# ------------------------------------------------------------
module Ansi
  # 256-colour codes, picked to read well on dark terminals.
  CODES = {
    reset: 0, bold: 1, dim: 2, italic: 3, underline: 4,
    red: 203, green: 114, yellow: 221, blue: 75,
    magenta: 176, cyan: 80, teal: 44, orange: 215,
    white: 255, gray: 244, slate: 109, pink: 211
  }.freeze

  ENABLED = $stdout.tty? && ENV['NO_COLOR'].nil? && ENV['TERM'] != 'dumb'

  module_function

  def sgr(code)
    return '' unless ENABLED

    code == 0 || code == 1 || code == 2 || code == 3 || code == 4 ?
      "\e[#{code}m" : "\e[38;5;#{code}m"
  end

  def paint(str, *styles)
    return str.to_s unless ENABLED

    seq = styles.map { |s| sgr(CODES.fetch(s)) }.join
    "#{seq}#{str}\e[0m"
  end

  # Request text arrives from the network, so neutralise control
  # characters before anything reaches the terminal.
  def safe(str)
    str.to_s.gsub(/[\x00-\x08\x0b-\x1f\x7f]/) { |c| format('\\x%02x', c.ord) }
  end

  # Visible length, ignoring colour escape codes (for alignment).
  def width(str)
    str.gsub(/\e\[[0-9;]*m/, '').length
  end

  # Truncate to a visible width, keeping colour codes intact-ish.
  def truncate(str, max)
    return str if width(str) <= max

    plain = str.gsub(/\e\[[0-9;]*m/, '')
    plain[0, [max - 1, 0].max] + '…'
  end

  def clear       = (print("\e[2J\e[3J\e[H") if ENABLED)
  def hide_cursor = (print("\e[?25l") if ENABLED)
  def show_cursor = (print("\e[?25h") if ENABLED)
end

# ------------------------------------------------------------
# Terminal geometry — lets the dashboard grow with the window
# so long URLs fit instead of being truncated.
# ------------------------------------------------------------
module Term
  module_function

  def cols
    if $stdout.tty?
      w = begin
        IO.console&.winsize&.last
      rescue StandardError
        nil
      end
      w = ENV['COLUMNS'].to_i if (w.nil? || w <= 0) && ENV['COLUMNS']
      return w if w && w.positive?
    end
    Config::MAX_WIDTH
  end

  # The box width, clamped to the configured bounds (2-col margin).
  def box_width
    (cols - 2).clamp(Config::MIN_WIDTH, Config::MAX_WIDTH)
  end
end

# ------------------------------------------------------------
# Network helpers  (named NetInfo so it never shadows stdlib Net)
# ------------------------------------------------------------
module NetInfo
  module_function

  def ips
    Socket.ip_address_list
          .select { |a| a.ipv4? && !a.ipv4_loopback? }
          .map(&:ip_address)
  rescue StandardError
    []
  end

  def primary_ip = ips.first || 'localhost'
end

# ------------------------------------------------------------
# Runs `cloudflared` in the background and captures the public
# https URL it prints. Fully optional: if cloudflared isn't
# installed, the server still runs locally and says so.
# ------------------------------------------------------------
class Tunnel
  # Match the quick-tunnel hostname, but never the api.* host that
  # cloudflared mentions in its own error output.
  URL_RE = %r{https://(?!api\.)[-a-z0-9]+\.trycloudflare\.com}i

  # :starting | :ready | :missing | :error
  attr_reader :state, :url, :err

  def initialize(port, dashboard)
    @port      = port
    @dashboard = dashboard
    @state     = :starting
    @url       = nil
    @err       = nil
    @wait      = nil
  end

  def start
    Thread.new { run }
  end

  def stop
    Process.kill('TERM', @wait.pid) if @wait&.pid
  rescue StandardError
    # already gone
  end

  private

  def run
    cmd = ['cloudflared', 'tunnel', '--url', "http://localhost:#{@port}"]
    Open3.popen2e(*cmd) do |_in, out, wait|
      @wait = wait
      out.each_line do |line|
        if @url.nil? && (m = line.match(URL_RE))
          @url   = m[0]
          @state = :ready
          @dashboard.render
        end
      end
    end
    # Process exited; if we never saw a URL, treat it as an error.
    if @url.nil?
      @state = :error
      @err   = 'cloudflared exited before publishing a URL'
      @dashboard.render
    end
  rescue Errno::ENOENT
    @state = :missing          # cloudflared not installed
    @dashboard.render
  rescue StandardError => e
    @state = :error
    @err   = e.message
    @dashboard.render
  end
end

# ------------------------------------------------------------
# Live stats
# ------------------------------------------------------------
class Stats
  METHOD_COLORS = {
    'GET' => :green, 'POST' => :yellow, 'PUT' => :blue,
    'DELETE' => :red, 'PATCH' => :magenta, 'OPTIONS' => :slate,
    'HEAD' => :teal
  }.freeze

  attr_reader :total

  def initialize
    @total     = 0
    @by_method = Hash.new(0)
    @started   = Time.now
    @mutex     = Mutex.new
  end

  def record(method)
    @mutex.synchronize do
      @total += 1
      @by_method[method] += 1
    end
  end

  def count(method) = @by_method[method]

  def uptime
    s = (Time.now - @started).to_i
    format('%02d:%02d:%02d', s / 3600, (s % 3600) / 60, s % 60)
  end

  def self.color_for(method) = METHOD_COLORS[method] || :gray
end

# ------------------------------------------------------------
# Tracks files in ./public and detects newly added ones
# ------------------------------------------------------------
class PublicDir
  def initialize(path)
    @path  = path
    @known = list
  end

  def list
    Dir.glob('**/*', base: @path)
       .select { |f| File.file?(File.join(@path, f)) }
       .sort
  rescue StandardError
    []
  end

  def newly_added
    current = list
    added   = current - @known
    @known  = current
    added
  end
end

# ------------------------------------------------------------
# A small ring buffer of the most recent request lines, so the
# live stream survives a full-board redraw instead of being
# wiped by the next Ansi.clear.
# ------------------------------------------------------------
class StreamLog
  def initialize(cap)
    @cap   = cap
    @lines = []
    @mutex = Mutex.new
  end

  def push(text)
    @mutex.synchronize do
      @lines.concat(text.split("\n"))
      @lines.shift while @lines.size > @cap
    end
  end

  def lines = @mutex.synchronize { @lines.dup }
end

# ------------------------------------------------------------
# Renders the dashboard. All drawing goes through one mutex so
# the request thread and the watcher thread never interleave.
# ------------------------------------------------------------
class Dashboard
  DRAW = Mutex.new

  def initialize(stats, public_dir, stream)
    @stats  = stats
    @public = public_dir
    @stream = stream
    @tunnel = nil
  end

  # Set after construction (the tunnel needs the dashboard first).
  attr_writer :tunnel

  def render(highlight: [])
    DRAW.synchronize do
      @inner = Term.box_width - 2      # recomputed each draw, follows resize
      Ansi.clear
      out = []
      out << top
      out << title_row
      out << divider
      out.concat(endpoint_rows)
      out.concat(tunnel_rows)
      out << divider
      out.concat(file_rows(highlight))
      out << divider
      out << stats_row
      out << bottom
      out << ''
      out.concat(stream_rows)
      out << ''
      out << Ansi.paint('  stream  ·  Ctrl+C to stop', :gray)
      out << ''
      print out.join("\n") + "\n"
      $stdout.flush
    end
  end

  # Record a request line, then redraw so it lands in the stream.
  def log_line(text)
    @stream.push(text)
    render
  end

  private

  def inner = @inner || (Config::MAX_WIDTH - 2)

  def row(content)
    content = Ansi.truncate(content, inner)
    pad = inner - Ansi.width(content)
    content += ' ' * pad if pad.positive?
    Ansi.paint('│', :slate) + content + Ansi.paint('│', :slate)
  end

  def top     = Ansi.paint("╭#{'─' * inner}╮", :slate)
  def bottom  = Ansi.paint("╰#{'─' * inner}╯", :slate)
  def divider = Ansi.paint("├#{'─' * inner}┤", :slate)

  def title_row
    live = @tunnel && @tunnel.state == :ready
    dot  = live ? Ansi.paint('●', :green) : Ansi.paint('●', :orange)
    row("  #{dot} " + Ansi.paint('zxman', :bold, :cyan) +
        Ansi.paint("   request catcher   0.0.0.0:#{Config::PORT}   up #{@stats.uptime}", :dim))
  end

  def endpoint_rows
    rows = [row(Ansi.paint('  endpoints', :dim))]
    NetInfo.ips.each do |ip|
      rows << row('    ' + Ansi.paint("http://#{ip}:#{Config::PORT}", :green, :bold))
    end
    rows << row('    ' + Ansi.paint("http://localhost:#{Config::PORT}", :dim))
    rows
  end

  def tunnel_rows
    return [] if @tunnel.nil?

    case @tunnel.state
    when :ready
      [row(Ansi.paint('  public url', :dim)),
       row('    ' + Ansi.paint(@tunnel.url, :magenta, :bold))]
    when :starting
      [row(Ansi.paint('  public url  ', :dim) + Ansi.paint('starting tunnel…', :orange))]
    when :missing
      [row(Ansi.paint('  public url  ', :dim) + Ansi.paint('cloudflared not installed — local only', :yellow))]
    else
      detail = @tunnel.err ? " (#{@tunnel.err})" : ''
      [row(Ansi.paint('  public url  ', :dim) + Ansi.paint("tunnel error — local only#{detail}", :yellow))]
    end
  end

  def file_rows(highlight)
    files = @public.list
    if files.empty?
      return [row(Ansi.paint('  public/  —  empty, drop a file in to get a link', :dim))]
    end

    public_base = (@tunnel && @tunnel.state == :ready) ? @tunnel.url : nil

    rows = [row(Ansi.paint('  public/  ', :dim) + Ansi.paint("(#{files.size})", :teal))]
    files.each do |f|
      local = Ansi.paint("http://#{NetInfo.primary_ip}:#{Config::PORT}/static/#{f}", :white)
      tag   = highlight.include?(f) ? Ansi.paint('  ★ NEW', :yellow, :bold) : ''
      rows << row("    #{local}#{tag}")
      if public_base
        rows << row('    ' + Ansi.paint('↳ ', :dim) +
                    Ansi.paint("#{public_base}/static/#{f}", :magenta))
      end
    end
    rows
  end

  def stats_row
    row('  ' +
        Ansi.paint(@stats.total.to_s, :bold, :white) + Ansi.paint(' reqs', :dim) + '    ' +
        Ansi.paint("#{@stats.count('GET')} GET",    :green)  + '   ' +
        Ansi.paint("#{@stats.count('POST')} POST",  :yellow) + '   ' +
        Ansi.paint("#{@stats.count('PUT')} PUT",    :blue)   + '   ' +
        Ansi.paint("#{@stats.count('DELETE')} DEL", :red))
  end

  def stream_rows
    lines = @stream.lines
    return [Ansi.paint('  … waiting for the first request', :dim)] if lines.empty?

    lines
  end
end

# ------------------------------------------------------------
# Persists each request to disk (one JSON line + one file)
# ------------------------------------------------------------
module Recorder
  WRITE = Mutex.new

  module_function

  def save(entry)
    WRITE.synchronize do
      File.open(Config::LOG, 'a') { |f| f.puts(JSON.generate(entry)) }
      stamp = Time.now.strftime('%Y%m%d-%H%M%S')
      name  = "#{stamp}-#{SecureRandom.hex(4)}.json"
      File.write(File.join(Config::HITS, name), JSON.pretty_generate(entry))
    end
  rescue StandardError => e
    warn Ansi.paint("  ! record failed: #{e.message}", :red)
  end
end

# ------------------------------------------------------------
# Serves ./public for /static/*  and captures everything else.
# One servlet mounted at '/', deciding internally whether a path
# is a static file or a hit, so the catcher can never swallow a
# /static request.
# ------------------------------------------------------------
class Router < WEBrick::HTTPServlet::AbstractServlet
  STATIC_PREFIX = '/static'
  CORS = {
    'Access-Control-Allow-Origin'  => '*',
    'Access-Control-Allow-Methods' => 'GET, POST, PUT, DELETE, PATCH, OPTIONS',
    'Access-Control-Allow-Headers' => '*'
  }.freeze

  def initialize(server, stats, dashboard)
    super(server)
    @stats     = stats
    @dashboard = dashboard
    @files     = WEBrick::HTTPServlet::FileHandler.new(
      server, Config::PUBLIC, FancyIndexing: Config::INDEXING
    )
  end

  %w[GET POST PUT DELETE PATCH OPTIONS HEAD].each do |verb|
    define_method("do_#{verb}") { |req, res| route(req, res) }
  end

  private

  def route(req, res)
    CORS.each { |k, v| res[k] = v }

    if req.request_method == 'OPTIONS'
      res.status = 204
      return
    end

    if static?(req.path)
      serve_static(req, res)
    else
      capture(req, res)
    end
  end

  def static?(path)
    path == STATIC_PREFIX || path.start_with?("#{STATIC_PREFIX}/")
  end

  # Hand the request to the file handler with the /static prefix
  # stripped. FileHandler resolves against path_info / script_name,
  # not path, so rewrite those on a copy of the request.
  def serve_static(req, res)
    sub = req.path.sub(/\A#{STATIC_PREFIX}/, '')
    sub = '/' if sub.empty?
    inner = req.dup
    inner.instance_variable_set(:@path, sub)
    inner.path_info   = sub
    inner.script_name = +''
    @files.service(inner, res)
  rescue WEBrick::HTTPStatus::NotFound
    res.status = 404
    res['Content-Type'] = 'text/plain'
    res.body = "404 Not Found: #{req.path}\n"
  end

  def capture(req, res)
    entry = build_entry(req)
    Recorder.save(entry)
    @stats.record(entry[:method])
    print_request(req, entry)   # redraws the board with the new line

    res.status = 200
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate(status: 'ok', seq: @stats.total)
  rescue StandardError => e
    warn Ansi.paint("  ! #{e.message}", :red)
    res.status = 500
    res['Content-Type'] = 'application/json'
    res.body = JSON.generate(error: e.message)
  end

  # Prefer the tunnel/proxy's forwarded client IP when present.
  def client_ip(req)
    fwd = req['cf-connecting-ip'] || req['x-forwarded-for']
    (fwd && !fwd.empty?) ? fwd.split(',').first.strip : req.peeraddr[3]
  rescue StandardError
    req.peeraddr[3]
  end

  # Request bodies are raw bytes; keep JSON valid and preserve
  # binary payloads as base64 instead of losing them.
  def encode_body(raw)
    return [nil, nil] if raw.nil? || raw.empty?

    capped = raw.byteslice(0, Config::BODY_CAP)
    utf8   = capped.dup.force_encoding('UTF-8')
    if utf8.valid_encoding?
      [utf8, nil]
    else
      [nil, Base64.strict_encode64(capped)]
    end
  end

  def build_entry(req)
    begin
      query = req.query
    rescue StandardError
      query = {}
    end
    text, b64 = encode_body(req.body)
    {
      time:        Time.now.iso8601,
      ip:          client_ip(req),
      method:      req.request_method,
      path:        req.path,
      query:       query,
      headers:     req.header.transform_values { |v| v.join(', ') },
      body:        text,
      body_base64: b64
    }.compact
  end

  def print_request(req, entry)
    color = Stats.color_for(entry[:method])
    stamp = Ansi.paint(Time.now.strftime('%H:%M:%S'), :gray)
    verb  = Ansi.paint(" #{entry[:method].ljust(6)}", color, :bold)
    path  = Ansi.paint(Ansi.safe(entry[:path]), :white)
    from  = Ansi.paint(Ansi.safe(entry[:ip].to_s), :dim)

    lines = ["  #{stamp}  #{verb} #{path}  #{from}"]
    if req.query_string && !req.query_string.empty?
      lines << "            #{Ansi.paint('?' + Ansi.safe(req.query_string), :cyan)}"
    end
    if entry[:body] && !entry[:body].empty?
      lines << "            #{Ansi.paint(Ansi.safe(entry[:body][0, 300]), :dim)}"
    elsif entry[:body_base64]
      lines << "            #{Ansi.paint("[binary body, #{entry[:body_base64].length}b base64]", :dim)}"
    end
    @dashboard.log_line(lines.join("\n"))
  end
end

# ------------------------------------------------------------
# Watches ./public and redraws when a new file shows up.
# ------------------------------------------------------------
class FileWatcher
  def initialize(public_dir, dashboard, interval: 1)
    @public    = public_dir
    @dashboard = dashboard
    @interval  = interval
  end

  def start
    Thread.new do
      loop do
        sleep @interval
        begin
          added = @public.newly_added
          @dashboard.render(highlight: added) unless added.empty?
        rescue StandardError => e
          warn Ansi.paint("  ! watcher: #{e.message}", :red)
        end
      end
    end
  end
end

# ------------------------------------------------------------
# Wire everything together and run
# ------------------------------------------------------------
class App
  MAX_BIND_ATTEMPTS = 3

  def initialize
    @stats     = Stats.new
    @public    = PublicDir.new(Config::PUBLIC)
    @stream    = StreamLog.new(Config::STREAM)
    @dashboard = Dashboard.new(@stats, @public, @stream)
    @tunnel    = Config::TUNNEL ? Tunnel.new(Config::PORT, @dashboard) : nil
    @dashboard.tunnel = @tunnel
    @server    = build_server
  end

  def run
    mount_routes
    install_signal_handlers
    Ansi.hide_cursor
    @dashboard.render
    FileWatcher.new(@public, @dashboard).start
    @tunnel&.start
    @server.start
  ensure
    @tunnel&.stop
    Ansi.show_cursor
  end

  private

  def build_server
    attempts = 0
    begin
      attempts += 1
      WEBrick::HTTPServer.new(
        BindAddress: '0.0.0.0',
        Port: Config::PORT,
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
      )
    rescue Errno::EADDRINUSE
      raise if attempts >= MAX_BIND_ATTEMPTS

      pids = `lsof -ti :#{Config::PORT} 2>/dev/null`.split
      if pids.empty?
        warn Ansi.paint("  ! port #{Config::PORT} is busy and no owning PID was found.", :red, :bold)
        warn Ansi.paint("    Free it, or run with another port:  PORT=8001 ruby server.rb", :dim)
        exit 1
      end

      unless Config::KILL_PORT
        warn Ansi.paint("  ! port #{Config::PORT} is busy (PID #{pids.join(', ')}).", :red, :bold)
        warn Ansi.paint("    Free it yourself, pick another port (PORT=8001 ruby server.rb),", :dim)
        warn Ansi.paint("    or re-run with KILL_PORT=1 to terminate the owning process.", :dim)
        exit 1
      end

      warn Ansi.paint("  ! port #{Config::PORT} busy (PID #{pids.join(', ')}) — freeing it…", :yellow)
      pids.each { |pid| Process.kill('TERM', pid.to_i) rescue nil }
      sleep 1
      retry
    end
  end

  def mount_routes
    # ONE mount only. The router decides static-vs-hit internally,
    # so there is no ordering conflict between '/' and '/static'.
    @server.mount('/', Router, @stats, @dashboard)
  end

  def install_signal_handlers
    done = false
    shutdown = lambda do |*|
      next if done
      done = true
      @tunnel&.stop
      Ansi.show_cursor
      puts "\n#{Ansi.paint("  ⬡ stopped — #{@stats.total} requests captured", :yellow)}"
      @server.shutdown
    end
    trap('INT',  &shutdown)
    trap('TERM', &shutdown)
  end
end

App.new.run
