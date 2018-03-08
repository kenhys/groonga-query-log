# Copyright (C) 2018  Kouhei Sutou <kou@clear-code.com>
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA

require "optparse"

require "groonga-query-log"
require "groonga-query-log/command-line"

module GroongaQueryLog
  module Command
    class CheckCrash < CommandLine
      def initialize
        setup_options
      end

      def run(arguments)
        begin
          log_paths = @option_parser.parse!(arguments)
        rescue OptionParser::InvalidOption => error
          $stderr.puts(error)
          return false
        end

        begin
          check(log_paths)
        rescue Interrupt
        rescue Error
          $stderr.puts($!.message)
          return false
        end

        true
      end

      private
      def setup_options
        @options = {}

        @option_parser = OptionParser.new do |parser|
          parser.version = VERSION
          parser.banner += " LOG1 ..."
        end
      end

      def open_output
        if @options[:output] == "-"
          yield($stdout)
        else
          File.open(@options[:output], "w") do |output|
            yield(output)
          end
        end
      end

      def check(log_paths)
        checker = Checker.new(log_paths)
        checker.check
      end

      class GroongaProcess
        attr_reader :pid
        attr_reader :start_time
        attr_reader :log_path
        attr_accessor :last_time
        def initialize(pid, start_time, log_path)
          @pid = pid
          @start_time = start_time
          @last_time = @start_time
          @log_path = log_path
        end
      end

      class Checker
        def initialize(log_paths)
          @general_log_parser = GroongaLog::Parser.new
          @query_log_parser = Parser.new
          split_log_paths(log_paths)

          @running_processes = {}
          @crash_processess = []
        end

        def check
          @general_log_parser.parse_paths(@general_log_paths) do |entry|
            check_general_log_entry(@general_log_parser.current_path,
                                    entry)
          end
          @running_processes.each_value do |process|
            @crash_processess << process
          end
          @crash_processess.each do |process|
            p [:crashed,
               process.start_time.iso8601,
               process.pid,
               process.log_path]

            start = process.start_time
            last = process.last_time
            @flushed = nil
            @unflushed_statistics = []
            @query_log_parser.parse_paths(@query_log_paths) do |statistic|
              next if statistic.start_time < start
              break if statistic.start_time > last
              check_query_log_statistic(@query_log_parser.current_path,
                                        statistic)
            end
            unless @unflushed_statistics.empty?
              puts("Unflushed statistics in #{start.iso8601}/#{last.iso8601}")
              @unflushed_statistics.each do |statistic|
                puts("#{statistic.start_time.iso8601}: #{statistic.raw_command}")
              end
            end
          end
        end

        private
        def split_log_paths(log_paths)
          @general_log_paths = []
          @query_log_paths = []
          log_paths.each do |log_path|
            sample_lines = GroongaLog::Input.open(log_path) do |log_file|
              log_file.each_line.take(10)
            end
            if sample_lines.any? {|line| Parser.target_line?(line)}
              @query_log_paths << log_path
            elsif sample_lines.any? {|line| GroongaLog::Parser.target_line?(line)}
              @general_log_paths << log_path
            end
          end
        end

        def check_general_log_entry(path, entry)
          # p [path, entry]
          case entry.log_level
          when :emergency, :alert, :critical, :error, :warning
            # p [entry.log_level, entry.message, entry.timestamp.iso8601]
          end

          case entry.message
          when /\Agrn_init:/
            process = @running_processes[entry.pid]
            if process
              @crash_processess << process
              @running_processes.delete(entry.pid)
            end
            process = GroongaProcess.new(entry.pid, entry.timestamp, path)
            @running_processes[entry.pid] = process
          when /\Agrn_fin \(\d+\)\z/
            n_leaks = $1.to_i
            @running_processes.delete(entry.pid)
            p [:leak, n_leask, entry.timestamp.iso8601] unless n_leaks.zero?
          else
            process = @running_processes[entry.pid]
            process.last_time = entry.timestamp if process
          end
        end

        def check_query_log_statistic(path, statistic)
          case statistic.command.command_name
          when "load"
            @flushed = false
            @unflushed_statistics << statistic
          when "io_flush"
            @flushed = true
            @unflushed_statistics.clear
          when "database_unmap"
            @unflushed_statistics.reject! do |statistic|
              statistic.command.name == "load"
            end
          when /\Atable_/
            @flushed = false
            @unflushed_statistics << statistic
          when /\Acolumn_/
            @flushed = false
            @unflushed_statistics << statistic
          end
        end
      end
    end
  end
end
