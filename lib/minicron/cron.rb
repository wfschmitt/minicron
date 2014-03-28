require 'shellwords'

module Minicron
  # Used to interact with the crontab on hosts over an ssh connection
  # TODO: I've had a moment of clarity, I don't need to do all the CRUD
  # using unix commands. I can cat the crontab, manipulate it in ruby
  # and then echo it back!
  class Cron
    # Initialise the cron class
    #
    # @param ssh [Minicron::Transport::SSH] instance
    def initialize(ssh)
      @ssh = ssh
    end

    # Escape the quotes in a command
    #
    # @param command [String]
    # @return [String]
    def escape_command(command)
      command.gsub(/\\|'/) { |c| "\\#{c}" }
    end

    # Build the minicron command to be used in the crontab
    #
    # @param command [String]
    # @param schedule [String]
    # @return [String]
    def build_minicron_command(command, schedule)
      # Escape any quotes in the command
      command = escape_command(command)

      "#{schedule} root minicron run '#{command}'"
    end

    # Used to find a string and replace it with another in the crontab by
    # using the sed command
    #
    # @param conn an instance of an open ssh connection
    # @param find [String]
    # @param replace [String]
    def find_and_replace(conn, find, replace)
      # TODO: move ssh test here for crontab permissions

      # Get the full crontab
      crontab = conn.exec!('cat /etc/crontab').to_s.strip

      # Replace the full string with the replacement string
      begin
        crontab[find] = replace
      rescue Exception => e
        raise Exception, "Unable to replace '#{find}' with '#{replace}' in the crontab, reason: #{e}"
      end

      # Echo the crontab back to the tmp crontab
      update = conn.exec!("echo #{crontab.shellescape} > /etc/crontab.tmp && echo 'y' || echo 'n'").to_s.strip

      # Throw an exception if it failed
      if update != 'y'
        raise Exception, "Unable to replace '#{find}' with '#{replace}' in the crontab"
      end

      # If it's a delete
      if replace == ''
        # Check the original line is no longer there
        grep = conn.exec!("grep -F \"#{find}\" /etc/crontab.tmp").to_s.strip

        # Throw an exception if we can't see our new line at the end of the file
        if grep != replace
          raise Exception, "Expected to find nothing when grepping crontab but found #{grep}"
        end
      else
        # Check the updated line is there
        grep = conn.exec!("grep -F \"#{replace}\" /etc/crontab.tmp").to_s.strip

        # Throw an exception if we can't see our new line at the end of the file
        if grep != replace
          raise Exception, "Expected to find '#{replace}' when grepping crontab but found #{grep}"
        end
      end

      # And finally replace the crontab with the new one now we now the change worked
      move = conn.exec!("mv /etc/crontab.tmp /etc/crontab && echo 'y' || echo 'n'").to_s.strip

      if move != 'y'
        raise Exception, 'Unable to move tmp crontab with updated crontab'
      end
    end

    # Add the schedule for this job to the crontab
    #
    # @param job [Minicron::Hub::Job] an instance of a job model
    # @param schedule [String] the job schedule as a string
    # @param conn an instance of an open ssh connection
    def add_schedule(job, schedule, conn = nil)
      # Open an SSH connection
      conn ||= @ssh.open

      # Prepare the line we are going to write to the crontab
      line = build_minicron_command(job.command, schedule)
      echo_line = "echo \"#{line}\" >> /etc/crontab && echo 'y' || echo 'n'"

      # Append it to the end of the crontab
      write = conn.exec!(echo_line).strip

      # Throw an exception if it failed
      if write != 'y'
        raise Exception, "Unable to write '#{line}' to the crontab"
      end

      # Check the line is there
      tail = conn.exec!('tail -n 1 /etc/crontab').strip

      # Throw an exception if we can't see our new line at the end of the file
      if tail != line
        raise Exception, "Expected to find '#{line}' at eof but found '#{tail}'"
      end
    end

    # Update the schedule for this job in the crontab
    #
    # @param job [Minicron::Hub::Job] an instance of a job model
    # @param old_schedule [String] the old job schedule as a string
    # @param new_schedule [String] the new job schedule as a string
    # @param conn an instance of an open ssh connection
    def update_schedule(job, old_schedule, new_schedule, conn = nil)
      # Open an SSH connection
      conn ||= @ssh.open

      # We are looking for the current value of the schedule
      find = build_minicron_command(job.command, old_schedule)

      # And replacing it with the updated value
      replace = build_minicron_command(job.command, new_schedule)

      # Replace the old schedule with the new schedule
      find_and_replace(conn, find, replace)
    end

    # Remove the schedule for this job from the crontab
    #
    # @param job [Minicron::Hub::Job] an instance of a job model
    # @param schedule [String] the job schedule as a string
    # @param conn an instance of an open ssh connection
    def delete_schedule(job, schedule, conn = nil)
      # Open an SSH connection
      conn ||= @ssh.open

      # We are looking for the current value of the schedule
      find = build_minicron_command(job.command, schedule)

      # Replace the old schedule with nothing i.e deleting it
      find_and_replace(conn, find, '')
    end

    # Delete a job and all it's schedules from the crontab
    #
    # @param job [Minicron::Hub::Job] a job instance with it's schedules
    # @param conn an instance of an open ssh connection
    def delete_job(job, conn = nil)
      conn ||= @ssh.open

      # Loop through each schedule and delete them one by one
      # TODO: share the ssh connection for this so it's faster when
      # many schedules exist
      # TODO: what if one schedule removal fails but others don't? Should
      # we try and rollback somehow or just return the job with half its
      # schedules deleted?
      job.schedules.each do |schedule|
        delete_schedule(job, schedule.formatted, conn)
      end
    end

    # Delete a host and all it's jobs from the crontab
    #
    # @param job [Minicron::Hub::Job] a job instance with it's schedules
    # @param conn an instance of an open ssh connection
    def delete_host(host, conn = nil)
      conn ||= @ssh.open

      # Loop through each job and delete them one by one
      # TODO: share the ssh connection for this so it's faster when
      # many schedules exist
      # TODO: what if one schedule removal fails but others don't? Should
      # we try and rollback somehow or just return the job with half its
      # schedules deleted?
      host.jobs.each do |job|
        delete_job(job, conn)
      end
    end
  end
end
