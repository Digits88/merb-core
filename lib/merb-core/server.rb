require 'etc'

module Merb

  # Server encapsulates the management of Merb daemons.
  class Server
    class << self

      # Start a Merb server, in either foreground, daemonized or cluster mode.
      #
      # ==== Parameters
      # port<~to_i>::
      #   The port to which the first server instance should bind to.
      #   Subsequent server instances bind to the immediately following ports.
      # cluster<~to_i>::
      #   Number of servers to run in a cluster.
      #
      # ==== Alternatives
      # If cluster is left out, then one process will be started. This process
      # will be daemonized if Merb::Config[:daemonize] is true.
      #
      # @api private
      def start(port, cluster=nil)

        @port = port
        @cluster = cluster

        if Merb::Config[:daemonize]
          pidfile = pid_file(port)
          pid = File.read(pidfile).chomp.to_i if File.exist?(pidfile)

          unless alive?(@port)
            remove_pid_file(@port)
            puts "Daemonizing..." if Merb::Config[:verbose]
            daemonize(@port)
          else
            Merb.fatal! "Merb is already running on port #{port}.\n" \
              "\e[0m   \e[1;31;47mpid file: \e[34;47m#{pidfile}" \
              "\e[1;31;47m, process id is \e[34;47m#{pid}."
          end
        else
          bootup
        end
      end

      # ==== Parameters
      # port<~to_s>:: The port to check for Merb instances on.
      #
      # ==== Returns
      # Boolean::
      #   True if Merb is running on the specified port.
      #
      # @api private
      def alive?(port)
        pidfile = pid_file(port)
        pid     = pid_in_file(pidfile)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::ENOENT
        false
      rescue Errno::EACCES => e
        Merb.fatal!("You don't have access to the PID file at #{pidfile}: #{e.message}")
      end

      def pid_in_file(pidfile)
        File.read(pidfile).chomp.to_i
      end

      # ==== Parameters
      # port<~to_s>:: The port of the Merb process to kill.
      # sig<~to_s>:: The signal to send to the process. Defaults to 9.
      #
      # ==== Alternatives
      # If you pass "all" as the port, the signal will be sent to all Merb
      # processes.
      #
      # @api private
      def kill(port, sig = "INT")
        # 9 => KILL
        # 2 => INT
        if sig.is_a?(Integer)
          sig = Signal.list.invert[sig]
        end
        
        Merb::BootLoader::BuildFramework.run
        # assume that if we kill master,
        # workers should be reaped, too
        if %w(main master all).include?(port)
          # if graceful exit is requested,
          # send INT to master process and
          # it's gonna do it's job
          #
          # Otherwise read pids from pid files
          # and try to kill each process in
          # turn
          if sig == "INT"
            kill_pid(sig, pid_file("main"))
          end
        else
          kill_pid(sig, pid_file(port))
        end
      end

      # Kills the process pointed at by the provided pid file.
      # @api private
      def kill_pid(sig, file)
        begin
          pid = pid_in_file(file)
          Merb.logger.fatal! "Killing pid #{pid} with #{sig}"
          Process.kill(sig, pid)
          FileUtils.rm(file) if File.exist?(file)
        rescue Errno::EINVAL
          Merb.logger.fatal! "Failed to kill PID #{pid} with #{sig}: '#{sig}' is an invalid " \
            "or unsupported signal number."
        rescue Errno::EPERM
          Merb.logger.fatal! "Failed to kill PID #{pid} with #{sig}: Insufficient permissions."
        rescue Errno::ESRCH
          FileUtils.rm file
          Merb.logger.fatal! "Failed to kill PID #{pid} with #{sig}: Process is " \
            "deceased or zombie."
        rescue Errno::EACCES => e
          Merb.logger.fatal! e.message
        rescue Errno::ENOENT => e
          # This should not cause abnormal exit, that's why
          # we do not use Merb.fatal but instead just
          # log with max level.
          Merb.logger.fatal! "Could not find a PID file at #{file}. Probably process is no longer running but pid file wasn't cleaned up."
        rescue Exception => e
          if !e.is_a?(SystemExit)
            Merb.logger.fatal! "Failed to kill PID #{pid.inspect} with #{sig.inspect}: #{e.message}"
          end
        end
      end

      # ==== Parameters
      # port<~to_s>:: The port of the Merb process to daemonize.
      #
      # @api private
      def daemonize(port)
        puts "About to fork..." if Merb::Config[:verbose]
        fork do
          Process.setsid
          exit if fork
          Merb.logger.warn! "In #{Process.pid}" if Merb.logger
          File.umask 0000
          STDIN.reopen "/dev/null"
          STDOUT.reopen "/dev/null", "a"
          STDERR.reopen STDOUT
          begin
            Dir.chdir Merb::Config[:merb_root]
          rescue Errno::EACCES => e
            Merb.fatal! "You specified #{Merb::Config[:merb_root]} " \
              "as the Merb root, but you did not have access to it.", e
          end
          at_exit { remove_pid_file(port) }
          Merb::Config[:port] = port
          bootup
        end
      rescue NotImplementedError => e
        Merb.fatal! "Daemonized mode is not supported on your platform", e
      end

      # Starts up Merb by running the bootloader and starting the adapter.
      #
      # @api private
      def bootup
        Merb.trap('TERM') { shutdown }

        puts "Running bootloaders..." if Merb::Config[:verbose]
        BootLoader.run
        puts "Starting Rack adapter..." if Merb::Config[:verbose]
        Merb.adapter.start(Merb::Config.to_hash)
      end

      # Change process user/group to those specified in Merb::Config.
      #
      # @api private
      def shutdown(status = 0)
        # reap_workers does exit but may not be called
        Merb::BootLoader::LoadClasses.reap_workers(status) if Merb::Config[:fork_for_class_load]
        # that's why we exit explicitly here
        exit(status)
      end

      def change_privilege
        if Merb::Config[:user] && Merb::Config[:group]
          Merb.logger.verbose! "About to change privilege to group " \
            "#{Merb::Config[:group]} and user #{Merb::Config[:user]}"
          _change_privilege(Merb::Config[:user], Merb::Config[:group])
        elsif Merb::Config[:user]
          Merb.logger.verbose! "About to change privilege to user " \
            "#{Merb::Config[:user]}"
          _change_privilege(Merb::Config[:user])
        else
          return true
        end
      end

      # Removes a PID file used by the server from the filesystem.
      # This uses :pid_file options from configuration when provided
      # or merb.<port>.pid in log directory by default.
      #
      # ==== Parameters
      # port<~to_s>::
      #   The port of the Merb process to whom the the PID file belongs to.
      #
      # ==== Alternatives
      # If Merb::Config[:pid_file] has been specified, that will be used
      # instead of the port based PID file.
      #
      # @api private
      def remove_pid_file(port)
        pidfile = pid_file(port)
        if File.exist?(pidfile)
          puts "Removing pid file #{pidfile} (port is #{port})..."
          FileUtils.rm(pidfile)
        end
      end

      # Stores a PID file on the filesystem.
      # This uses :pid_file options from configuration when provided
      # or merb.<port>.pid in log directory by default.
      #
      # ==== Parameters
      # port<~to_s>::
      #   The port of the Merb process to whom the the PID file belongs to.
      #
      # ==== Alternatives
      # If Merb::Config[:pid_file] has been specified, that will be used
      # instead of the port based PID file.
      #
      # @api private
      def store_pid(port)
        store_details(port)
      end

      # Delete the pidfile for the specified port.
      #
      # @api private
      def remove_pid(port)
        FileUtils.rm(pid_file(port)) if File.file?(pid_file(port))
      end

      # Stores a PID file on the filesystem.
      # This uses :pid_file options from configuration when provided
      # or merb.<port>.pid in log directory by default.
      #
      # ==== Parameters
      # port<~to_s>::
      #   The port of the Merb process to whom the the PID file belongs to.
      #
      # ==== Alternatives
      # If Merb::Config[:pid_file] has been specified, that will be used
      # instead of the port based PID file.
      #
      # @api private
      def store_details(port = nil)
        file = pid_file(port)
        begin
          FileUtils.mkdir_p(File.dirname(file))
        rescue Errno::EACCES => e
          Merb.fatal! "You tried to store Merb logs in #{File.dirname(file)}, " \
            "but you did not have access.", e
        end
        Merb.logger.warn! "Storing #{type} file to #{file}..." if Merb::Config[:verbose]
        begin
          File.open(file, 'w'){ |f| f.write(Process.pid.to_s) }
        rescue Errno::EACCES => e
          Merb.fatal! "You tried to access #{file}, but you did not " \
            "have permission", e
        end
      end

      # Gets the pid file for the specified port.
      #
      # ==== Parameters
      # port<~to_s>::
      #   The port of the Merb process to whom the the PID file belongs to.
      #
      # ==== Returns
      # String::
      #   Location of pid file for specified port. If clustered and pid_file option
      #   is specified, it adds the port value to the path.
      #
      # @api private
      def pid_file(port)
        pidfile = Merb::Config[:pid_file] || (Merb.log_path / "merb.%s.pid")
        pidfile % port
      end

      # Get a list of the pid files.
      #
      # ==== Returns
      # Array::
      #   List of pid file paths. If not clustered, array contains a single path.
      #
      # @api private
      def pid_files
        if Merb::Config[:pid_file]
          if Merb::Config[:cluster]
            Dir[Merb::Config[:pid_file] % "*"]
          else
            [ Merb::Config[:pid_file] ]
          end
        else
          Dir[Merb.log_path / "merb.*.pid"]
        end
       end

      # Change privileges of the process to the specified user and group.
      #
      # ==== Parameters
      # user<String>:: The user who should own the server process.
      # group<String>:: The group who should own the server process.
      #
      # ==== Alternatives
      # If group is left out, the user will be used as the group.
      #
      # @api private
      def _change_privilege(user, group=user)

        Merb.logger.warn! "Changing privileges to #{user}:#{group}"

        uid, gid = Process.euid, Process.egid

        begin
          target_uid = Etc.getpwnam(user).uid
        rescue ArgumentError => e
          Merb.fatal!(
            "You tried to use user #{user}, but no such user was found", e)
          return false
        end

        begin
          target_gid = Etc.getgrnam(group).gid
        rescue ArgumentError => e
          Merb.fatal!(
            "You tried to use group #{group}, but no such group was found", e)
          return false
        end

        if uid != target_uid || gid != target_gid
          # Change process ownership
          Process.initgroups(user, target_gid)
          Process::GID.change_privilege(target_gid)
          Process::UID.change_privilege(target_uid)
        end
        true
      rescue Errno::EPERM => e
        Merb.fatal! "Couldn't change user and group to #{user}:#{group}", e
        false
      end

      # @api private
      def add_irb_trap
        Merb.trap('INT') do
          if @interrupted
            puts "Exiting\n"
            exit
          end

          @interrupted = true
          puts "Interrupt a second time to quit"
          Kernel.sleep 1.5
          ARGV.clear # Avoid passing args to IRB

          if @irb.nil?
            require 'irb'
            IRB.setup(nil)
            @irb = IRB::Irb.new(nil)
            IRB.conf[:MAIN_CONTEXT] = @irb.context
          end

          Merb.trap(:INT) { @irb.signal_handle }
          catch(:IRB_EXIT) { @irb.eval_input }

          puts "Exiting IRB mode, back in server mode"
          @interrupted = false
          add_irb_trap
        end
      end
    end
  end
end
