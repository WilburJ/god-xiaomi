module God
  module CLI

    class Command
      def initialize(command, options, args)
        @command = command
        @options = options
        @args = args

        dispatch
      end

      def setup
        # connect to drb unix socket
        DRb.start_service("druby://127.0.0.1:0")
        @server = DRbObject.new(nil, God::Socket.socket(@options[:port]))

        # ping server to ensure that it is responsive
        begin
          @server.ping
        rescue DRb::DRbConnError
          puts "The server is not available (or you do not have permissions to access it)"
          abort
        end
      end

      def dispatch
        if %w{load status signal log quit terminate}.include?(@command)
          setup
          send("#{@command}_command")
        elsif %w{start stop restart monitor unmonitor remove}.include?(@command)
          setup
          lifecycle_command
        elsif @command == 'check'
          check_command
        else
          puts "Command '#{@command}' is not valid. Run 'god --help' for usage"
          abort
        end
      end

      def load_command
        file = @args[1]
        action = @args[2] || 'leave'

        unless ['stop', 'remove', 'leave', ''].include?(action)
          puts "Command '#{@command}' action must be either 'stop', 'remove' or 'leave'"
          exit(1)
        end

        puts "Sending '#{@command}' command with action '#{action}'"
        puts

        unless File.exist?(file)
          abort "File not found: #{file}"
        end

        affected, errors, removed = *@server.running_load(File.read(file), File.expand_path(file), action)

        # output response
        unless affected.empty?
          puts 'The following tasks were affected:'
          affected.each do |w|
            puts '  ' + w
          end
        end

        unless removed.empty?
          puts 'The following tasks were removed:'
          removed.each do |w|
            puts '  ' + w
          end
        end

        unless errors.empty?
          puts errors
          exit(1)
        end
      end


      def print_status(name, state, pid)
        status = ""
        start_time = ""
        if state == :up
          status = "running"
          if ! pid.nil? && File.exist?("/proc/#{pid}")
            jiffies =  IO.read("/proc//#{pid}/stat").split(/\s/)[21].to_i
            uptime = IO.readlines("/proc/stat").find {|t| t =~ /^btime/ }.split(/\s/)[1].strip.to_i
            start_time = Time.at(uptime + jiffies / 100).strftime("%Y-%m-%d %H:%M:%S")
          else
            status = 'flapping'
            start_time = "Can't find pid:#{pid}"
          end
        elsif state == :unmonitored
          status = "stop"
        else
          status = "something error"
        end
        print "#{name}[#{pid}]: #{status} "
        print "(#{start_time})" unless start_time.empty? 
        print "\n"

      end

      def status_command
        exitcode = 0
        statuses = @server.status
        groups = {}
        statuses.each do |name, status|
          g = status[:group] || ''
          groups[g] ||= {}
          groups[g][name] = status
        end

        if item = @args[1]
          if single = statuses[item]
            # specified task (0 -> up, 1 -> unmonitored, 2 -> other)
            state = single[:state]
            pid = single.fetch :pid, nil
            print_status(item, state, pid)
            exitcode = state == :up ? 0 : (state == :unmonitored ? 1 : 2)
          elsif groups[item]
            # specified group (0 -> up, N -> other)
            puts "#{item}:"
            groups[item].keys.sort.each do |name|
              state = groups[item][name][:state]
              pid = groups[item][name].fetch :pid, nil
              print "  "
              print_status(name, state, pid)
              #puts "#{name}[#{pid}]: #{state}"
              exitcode += 1 unless state == :up
            end
          else
            puts "Task or Group '#{item}' not found."
            exit(1)
          end
        else
          # show all groups and watches
          groups.keys.sort.each do |group|
            puts "#{group}:" unless group.empty?
            groups[group].keys.sort.each do |name|
              state = groups[group][name][:state]
              pid = groups[group][name].fetch :pid, nil
              print "  " unless group.empty?
              print_status(name, state, pid)
              #puts "#{name}[#{pid}]: #{state}"
            end
          end
        end

        exit(exitcode)
      end

      def signal_command
        # get the name of the watch/group
        name = @args[1]
        signal = @args[2]

        puts "Sending signal '#{signal}' to '#{name}'"

        t = Thread.new { loop { sleep(1); STDOUT.print('.'); STDOUT.flush; sleep(1) } }

        watches = @server.signal(name, signal)

        # output response
        t.kill; STDOUT.puts
        unless watches.empty?
          puts 'The following watches were affected:'
          watches.each do |w|
            puts '  ' + w
          end
        else
          puts 'No matching task or group'
        end
      end

      def log_command
        begin
          Signal.trap('INT') { exit }
          name = @args[1]

          unless name
            puts "You must specify a Task or Group name"
            exit!
          end

          puts "Please wait..."
          t = Time.at(0)
          loop do
            print @server.running_log(name, t)
            t = Time.now
            sleep 0.25
          end
        rescue God::NoSuchWatchError
          puts "No such watch"
        rescue DRb::DRbConnError
          puts "The server went away"
        end
      end

      def quit_command
        begin
          @server.terminate
          abort 'Could not stop god'
        rescue DRb::DRbConnError
          puts 'Stopped god'
        end
      end

      def terminate_command
        t = Thread.new { loop { STDOUT.print('.'); STDOUT.flush; sleep(1) } }
        if @server.stop_all
          t.kill; STDOUT.puts
          puts 'Stopped all watches'
        else
          t.kill; STDOUT.puts
          puts "Could not stop all watches within #{@server.terminate_timeout} seconds"
        end

        begin
          @server.terminate
          abort 'Could not stop god'
        rescue DRb::DRbConnError
          puts 'Stopped god'
        end
      end

      def check_command
        Thread.new do
          begin
            event_system = God::EventHandler.event_system
            puts "using event system: #{event_system}"

            if God::EventHandler.loaded?
              puts "starting event handler"
              God::EventHandler.start
            else
              puts "[fail] event system did not load"
              exit(1)
            end

            puts 'forking off new process'

            pid = fork do
              loop { sleep(1) }
            end

            puts "forked process with pid = #{pid}"

            God::EventHandler.register(pid, :proc_exit) do
              puts "[ok] process exit event received"
              exit!(0)
            end

            sleep(1)

            puts "killing process"

            ::Process.kill('KILL', pid)
            ::Process.waitpid(pid)
          rescue => e
            puts e.message
            puts e.backtrace.join("\n")
          end
        end

        sleep(2)

        puts "[fail] never received process exit event"
        exit(1)
      end

      def lifecycle_command
        # get the name of the watch/group
        name = @args[1]

        puts "Sending '#{@command}' command"

        t = Thread.new { loop { sleep(1); STDOUT.print('.'); STDOUT.flush; sleep(1) } }

        # send @command
        watches = @server.control(name, @command)

        # output response
        t.kill; STDOUT.puts
        unless watches.empty?
          puts 'The following watches were affected:'
          watches.each do |w|
            puts '  ' + w
          end
        else
          puts 'No matching task or group'
        end
      end
    end # Command

  end
end
