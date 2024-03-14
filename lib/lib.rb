require 'eventmachine'
require 'faye/websocket'
require 'json'
require 'thread'
require 'open3'

class Buddy
  def initialize
    @id = 0
    @ws = nil
    @queue = Queue.new
    @results = {}
    @session_id = nil
    @listeners ||= Hash.new do |hash, key|
      hash[key] = []
    end
  end

  def boot
    __kill_existing_chrome_processes__
    __create_tmp_directories__
    __start_chrome_process__
    __start_websocket_listener__
    __init_session__
  end

  def __kill_existing_chrome_processes__
    results = `ps -e | grep remote-debugging-port=9222`
    results.each_line do |line|
      pid = line.split(" ").first
      `kill -9 #{pid} 2>/dev/null`
    end
  end

  def __init_session__
    command "Target.setDiscoverTargets" do
      { discover: true }
    end

    result = command "Target.createBrowserContext" do {} end
    browser_context_id = result["result"]["browserContextId"]
    result = command "Target.createTarget" do
      {
        url: "about:blank",
        browserContextId: browser_context_id,
      }
    end

    target_id = result["result"]["targetId"]
    result = command "Target.attachToTarget" do
      { targetId: target_id, flatten: true }
    end

    session_id = result["result"]["sessionId"]
    command "Page.enable", session_id: session_id do
      { }
    end

    # maximize browser window
    result = command "Browser.getWindowForTarget" do
      { targetId: target_id }
    end

    window_id = result["result"]["windowId"]
    command "Browser.setWindowBounds" do
      {
        windowId: window_id,
        bounds: {
          windowState: "maximized",
        },
      }
    end

    command "Page.setDownloadBehavior", session_id: session_id do
      {
        behavior: "allow",
        downloadPath: File.expand_path("~/Downloads"),
        allowAndName: true,
      }
    end

    @session_id = session_id
  end

  def set_session_id! session_id
    @session_id = session_id
  end

  def start_browser

  end

  def command method, session_id: nil, &block
    command_async method, session_id: session_id, &block

    loop do
      if @results[@id]
        result = @results[@id]
        @results.delete(@id)
        return result
      end
      sleep 0.01
    end
  end

  def command_async method, session_id: nil, &block
    data = {}
    data = block.call if block
    @id += 1
    hash = {
      id: @id,
      method: method,
    }

    if session_id || @session_id
      hash[:sessionId] = session_id || @session_id
    end

    if data
      hash[:params] = data
    else
      hash[:params] = {}
    end

    @queue.push(hash)
  end

  def __start_chrome_process__
    log_file = "./logs/chrome.log"
    command = "nohup #{__chrome_start_command__} &> #{log_file} 2>&1 &"
    puts command
    @stdin, @stdout, @stderr, @wait_thread = Open3.popen3 command
    @pid = @wait_thread[:pid]

    File.write log_file, ""

    loop do
      puts "* INFO: Waiting for Chrome to start"
      File.read(log_file).each_line do |line|
        puts line
        if line.include? "DevTools listening on"
          @ws_url = line.split(" ").last
          break
        end
      end

      if @ws_url
        break
      end

      sleep 1
    end
  end

  def __start_websocket_listener__
    log_file = "./logs/ws.log"
    File.write log_file, ""
    @ws_thread = Thread.new do
      EM.run do
        @ws = Faye::WebSocket::Client.new(@ws_url)

        @ws.on :open do |event|
          File.write log_file, "Connection opened\n", mode: "a"
          puts 'Connection opened'
        end

        @ws.on :message do |event|
          File.write log_file, "#{event.data}\n", mode: "a"
          data = JSON.parse(event.data)
          @results[data["id"]] = data
          @listeners[data["method"]].each do |listener|
            listener.call data
          end
        end

        @ws.on :close do |event|
          File.write log_file, "Connection closed\n", mode: "a"
          puts 'Connection closed'
          EM.stop
        end

        Thread.new do
          while data = @queue.pop
            @ws.send data.to_json
          end
        end
      end
    end
  end

  def goto url
    command "Page.navigate" do
      { url: url }
    end
  end

  def docs
    system "open https://chromedevtools.github.io/devtools-protocol/"
  end

  def __create_tmp_directories__
    if !Dir.exist? "./user-data-dir"
      Dir.mkdir "./user-data-dir"
    end

    if !Dir.exist? "./logs"
      Dir.mkdir "./logs"
    end
  end

  def ws_url
    @ws_url
  end

  def register_listener method_name, &block
    @listeners[method_name] ||= []
    @listeners[method_name] << block
  end

  def listeners
    @listeners
  end

  def __chrome_start_command__
    command = ["\"./bin/Chromium.app/Contents/MacOS/Chromium\"",
               "--hide-scrollbars",
               "--mute-audio",
               "--enable-automation",
               "--disable-web-security",
               "--disable-session-crashed-bubble",
               "--disable-breakpad",
               "--disable-sync",
               "--no-first-run",
               "--use-mock-keychain",
               "--keep-alive-for-test",
               "--disable-popup-blocking",
               "--disable-extensions",
               "--disable-hang-monitor",
               "--disable-features=site-per-process,TranslateUI",
               "--disable-translate",
               "--disable-background-networking",
               "--enable-features=NetworkService,NetworkServiceInProcess",
               "--disable-background-timer-throttling",
               "--disable-backgrounding-occluded-windows",
               "--disable-client-side-phishing-detection",
               "--disable-default-apps",
               "--disable-dev-shm-usage",
               "--disable-ipc-flooding-protection",
               "--disable-prompt-on-repost",
               "--disable-renderer-backgrounding",
               "--force-color-profile=srgb",
               "--metrics-recording-only",
               "--safebrowsing-disable-auto-update",
               "--password-store=basic",
               "--no-startup-window",
               "--remote-debugging-port=9222",
               "--remote-debugging-address=127.0.0.1",
               "--window-size=1024,768",
               "--user-data-dir=./user-data-dir"].join " "
  end

  def eval_js expression
    command "Runtime.evaluate" do
      { expression: expression }
    end
  end

  def input_key_down key
    command_async "Input.dispatchKeyEvent" do
      {
        type: "keyDown",
        text: key,
      }
    end
  end

  def input_key_up key
    command_async "Input.dispatchKeyEvent" do
      {
        type: "keyUp",
        text: key,
      }
    end
  end

  def type text
    text.each_char do |char|
      input_key_down char
    end
  end
end

$Buddy ||= Buddy.new
def restart_browser
  $Buddy = Buddy.new
  $Buddy.boot
end

original_verbose, $VERBOSE = $VERBOSE, nil
def method_missing method, *args, &block
  if $Buddy.respond_to? method
    define_singleton_method method do |*args, &block|
      $Buddy.send method, *args, &block
    end

    send method, *args, &block
  else
    super
  end
end
$VERBOSE = original_verbose
