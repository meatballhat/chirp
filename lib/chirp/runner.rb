# frozen_string_literal: true

require 'English'
require 'fileutils'
require 'json'
require 'socket'
require 'time'

module Chirp
  class Runner
    autoload :Child, 'chirp/runner/child'

    attr_reader :action

    def initialize(args = ARGV.clone)
      @action = args.first || 'scripts'
      $stdout.sync = true
      $stderr.sync = true
    end

    def run!
      send("perform_#{action}")
    end

    private

    %w[pushback sendstats pullcommitpush].each do |script_name|
      define_method("perform_#{script_name}") do
        Process.exec(internal_script(script_name))
      end
    end

    def perform_help
      $stdout.puts <<~EOF
        Usage: #{File.basename($PROGRAM_NAME)} <command>

        Available commands:
          - dumplogs
          - pullcommitpush
          - pushback
          - scripts
          - sendstats

      EOF
      0
    end

    def perform_dumplogs
      Process.exec(internal_script('dumplogs'), logs_dir)
    end

    def perform_scripts
      started = {}
      completed = {}
      FileUtils.mkdir_p(logs_dir)

      scripts.each do |script|
        next unless File.executable?(script)

        logfile = File.join(logs_dir, "#{File.basename(script)}.log")
        $stdout.puts "* ---> Spawning #{script.inspect}"
        pid = Process.spawn(script, %i[out err] => [logfile, 'w'])
        now = Time.now.utc
        started[pid] = Child.new(script, 0, pid, now, now)
      end

      print_forever

      loop do
        break if started.empty?

        started.clone.map do |pid, _child|
          next unless Process.waitpid(pid, Process::WNOHANG)

          child = started.delete(pid)
          child.completed_time = Time.now.utc
          child.exit_status = $CHILD_STATUS.exitstatus

          $stdout.puts "---> Done with #{child.script.inspect}, " \
                       "exit #{child.exit_status}"

          completed[pid] = child
        end

        sleep 0.2
      end

      summarize(completed)
      completed.values.map(&:exit_status).reduce(:+) || 0
    end

    def scripts
      @scripts ||= Dir.glob(
        File.expand_path("#{scripts_dir}/*")
      ).select do |script|
        script_filter =~ script
      end
    end

    def scripts_dir
      return @scripts_dir if @scripts_dir
      @scripts_dir = ENV.fetch(
        'CHIRP_SCRIPTS',
        File.expand_path('./scripts', __dir__)
      )
      ENV['CHIRP_SCRIPTS'] = @scripts_dir
      @scripts_dir
    end

    def internal_script(basename)
      File.join(internal_scripts_dir, basename)
    end

    def internal_scripts_dir
      @internal_scripts_dir ||= File.expand_path(
        './internal-scripts', __dir__
      )
    end

    def summary_output_file
      return @summary_output_file if @summary_output_file
      @summary_output_file = Pathname.new(
        File.expand_path(
          ENV.fetch('CHIRP_SUMMARY_OUTPUT', 'chirp.json')
        )
      )
      ENV['CHIRP_SUMMARY_OUTPUT'] = @summary_output_file.to_s
      @summary_output_file
    end

    def logs_dir
      @logs_dir ||= ENV.fetch(
        'CHIRP_LOGS', File.expand_path('../../log', __dir__)
      )
    end

    def script_filter
      @script_filter ||= /#{ENV['CHIRP_SCRIPT_FILTER'] || '.*'}/
    end

    def print_forever
      Thread.start do
        loop do
          %w[◴ ◷ ◶ ◵].each do |chr|
            $stderr.write "\r  "
            $stderr.write "\r#{chr} "
            sleep 0.1
          end
        end
      end
    end

    def summarize(completed)
      $stdout.puts '---> ALL DONE!'
      summary = {
        timestamp: Time.now.utc.iso8601(5),
        queue: ENV.fetch('QUEUE', 'unknown'),
        dist: ENV.fetch('DIST', 'unknown'),
        site: ENV.fetch('SITE', 'unknown'),
        infra: infra
      }

      completed.each_value do |child|
        summary["#{child.basename}_duration_ms"] = child.duration_ms
        summary["#{child.basename}_exit_code"] = child.exit_status

        $stdout.puts "* ---> #{child.basename} #{child.duration_ms}ms " \
          "(exit #{child.exit_status})"
      end

      summary_output_file.write(JSON.pretty_generate(summary))

      $stdout.puts "* ---> Summary: #{summary_output_file}"
    end

    private def infra
      return ENV['INFRA'] if ENV.key?('INFRA')
      case Socket.gethostname
      when /\bec2\b/ then 'ec2'
      when /\bgce\b/ then 'gce'
      when /\bpacket\b/ then 'packet'
      when /\b(wjb|mac)\b/i then 'macstadium'
      else 'unknown'
      end
    end
  end
end
