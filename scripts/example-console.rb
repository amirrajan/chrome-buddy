restart_browser
command "Console.enable"
register_event_listener "Console.messageAdded" do |message|
  if !File.exist? "./logs/console.log"
    File.write "./logs/console.log", ""
  end

  File.write "./logs/console.log", "#{JSON::pretty_generate message}\n", mode: "a"
  puts message
end
goto "http://amirrajan.net"
eval_js "console.log('Hello from Ruby')"
