original_verbose, $VERBOSE = $VERBOSE, nil
REQUIRES = [
  './lib/lib.rb',
]
REQUIRES.each { |f| require f }
$VERBOSE = original_verbose

def reload_buddy
  REQUIRES.each { |f| load f }
end

def start_watcher_thread
  @reload_thread = Thread.new do
    @reload_mtimes ||= {}
    REQUIRES.each do |f|
      @reload_mtimes[f] = File.mtime f
    end
    loop do
      changed_k, changed_v = REQUIRES.find do |f|
        @reload_mtimes[f] != File.mtime(f)
      end
      if changed_k
        puts "* INFO: Reloaded #{changed_k}."
        begin
          reload_buddy
        rescue Exception => e
          puts "* ERROR: Reloading failed\n#{e}"
        end
      end
      REQUIRES.each do |f|
        @reload_mtimes[f] = File.mtime(f)
      end
      sleep 1
    end
  end
end

def initialize_repl
  reload_buddy
  start_watcher_thread
end
