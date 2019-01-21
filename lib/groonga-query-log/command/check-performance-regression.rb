# Copyright (C) 2011-2018  Kouhei Sutou <kou@clear-code.com>
# Copyright (C) 2019 Kentaro Hayashi <hayashi@clear-code.com>
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
require "json"

require "groonga-query-log"
require "groonga-query-log/command-line"

require "groonga-query-log/command/analyzer"
require "groonga-query-log/command/analyzer/sized-statistics"

module GroongaQueryLog
  module Command
    class CheckPerformanceRegression < CommandLine
      CACHED_QUERY_OPERAION_COUNT = 1
      NSEC_IN_SECONDS = (1000 * 1000 * 1000.0)

      def initialize(options={})
        setup_options
        @output = options[:output] || $stdout
      end

      def run(arguments)
        begin
          @option_parser.parse!(arguments)
        rescue OptionParser::InvalidOption => error
          $stderr.puts(error)
          return false
        end

        unless @options[:input_old_query] and @options[:input_new_query]
          $stderr.puts("query logs is not specified. use --input-old-query and --input-new-query")
          return false
        end

        if @options[:output].kind_of?(String)
          if @options[:output] == "-"
            @output = $stdio
          else
            @output = File.open(@options[:output], "w+")
          end
        end

        old_statistics = analyze(@options[:input_old_query])
        new_statistics = analyze(@options[:input_new_query])

        old_queries, new_queries = group_statistics(old_statistics, new_statistics)

        statistics = []
        old_queries.keys.each do |query|
          old_elapsed_nsec = average_elapsed_nsec(old_queries[query])
          new_elapsed_nsec = average_elapsed_nsec(new_queries[query])
          ratio = elapsed_ratio(old_elapsed_nsec, new_elapsed_nsec)
          statistics << {
            :query => query,
            :ratio => ratio,
            :old_elapsed_nsec => old_elapsed_nsec,
            :new_elapsed_nsec => new_elapsed_nsec
          }
        end

        statistics.sort! do |a, b|
          b[:ratio] <=> a[:ratio]
        end

        statistics.each do |statistic|
          query = statistic[:query]
          old_elapsed_nsec = statistic[:old_elapsed_nsec]
          new_elapsed_nsec = statistic[:new_elapsed_nsec]

          if slow_response?(old_elapsed_nsec, new_elapsed_nsec)
            @output.puts("Query: #{query}")
            ratio = statistic[:ratio]
            @output.puts("  %s" % [
              format_elapsed_calculated_ratio(ratio, old_elapsed_nsec, new_elapsed_nsec)
            ])
            @output.puts("  Operations:")
            old_operation_nsecs = average_elapsed_operation_nsecs(old_queries[query])
            new_operation_nsecs = average_elapsed_operation_nsecs(new_queries[query])
            old_operation_nsecs.each_with_index do |operation, index|
              new_operation = new_operation_nsecs[index]
              if slow_operation?(operation[:elapsed], new_operation[:elapsed])
                @output.puts("    Operation: %s %s" % [
                  operation[:name],
                  format_elapsed_ratio(operation[:elapsed],
                                       new_operation[:elapsed])
                ])
              end
            end
          end
        end

        if @output.kind_of?(File)
          @output.close
        end

        true
      end

      private
      def elapsed_ratio(old_elapsed_nsec, new_elapsed_nsec)
        if old_elapsed_nsec == 0 and new_elapsed_nsec == 0
          0.0
        elsif old_elapsed_nsec == 0 and new_elapsed_nsec > 0
          if new_elapsed_nsec / NSEC_IN_SECONDS < @options[:slow_response_threshold]
            -Float::INFINITY
          else
            Float::INFINITY
          end
        else
          (new_elapsed_nsec / old_elapsed_nsec) * 100 - 100
        end
      end

      def average_elapsed_nsec(statistics)
        elapsed_times = statistics.collect do |statistic|
          statistic.elapsed
        end
        elapsed_times.inject(:+).to_f / elapsed_times.size
      end

      def average_elapsed_operation_nsecs(statistics)
        operations = []
        statistics.first.operations.each_with_index do |operation, index|
          elapsed_times = statistics.collect do |statistic|
            statistic.operations[index][:relative_elapsed]
          end
          operations << {
            :name => statistics.first.operations[index][:name],
            :elapsed => elapsed_times.inject(:+).to_f / elapsed_times.size
          }
        end
        operations
      end

      def slow_response?(old_elapsed_nsec, new_elapsed_nsec)
        ratio = elapsed_ratio(old_elapsed_nsec, new_elapsed_nsec)
        elapsed_sec = ((new_elapsed_nsec - old_elapsed_nsec) / NSEC_IN_SECONDS)
        slow_response = ((ratio >= @options[:slow_response_ratio]) and
                        (elapsed_sec >= @options[:slow_response_threshold]))
        slow_response
      end

      def slow_operation?(old_elapsed_nsec, new_elapsed_nsec)
        ratio = new_elapsed_nsec / old_elapsed_nsec * 100 - 100
        elapsed_sec = ((new_elapsed_nsec - old_elapsed_nsec) / NSEC_IN_SECONDS)
        slow_operation = ((ratio >= @options[:slow_operation_ratio]) and
                         (elapsed_sec >= @options[:slow_operation_threshold]))
        slow_operation
      end

      def format_elapsed_calculated_ratio(ratio, old_elapsed_nsec, new_elapsed_nsec)
        "Before(average): %d (msec) After(average): %d (msec) Ratio: (%s%.2f%%)" % [
          old_elapsed_nsec / 1000 / 1000,
          new_elapsed_nsec / 1000 / 1000,
          ratio > 0 ? '+' : '',
          ratio
        ]
      end

      def format_elapsed_ratio(old_elapsed_nsec, new_elapsed_nsec)
        ratio = elapsed_ratio(old_elapsed_nsec, new_elapsed_nsec)
        format_elapsed_calculated_ratio(ratio, old_elapsed_nsec, new_elapsed_nsec)
      end

      def cached_query?(statistics)
        (statistics.operations.count == CACHED_QUERY_OPERAION_COUNT) and
          (statistics.operations[0][:name] == 'cache')
      end

      def different_query?(old_statistics, new_statistics)
        old_statistics.raw_command != new_statistics.raw_command
      end

      def setup_options
        @options = {}
        @options[:n_entries] = 1000
        @options[:order] = 'start-time'
        @options[:slow_operation_ratio] = 10
        @options[:slow_response_ratio] = 0
        @options[:slow_operation_threshold] = 0.1
        @options[:slow_response_threshold] = 0.2
        @options[:input_old_query] = nil
        @options[:input_new_query] = nil

        @option_parser = OptionParser.new do |parser|
          parser.version = VERSION

          parser.on("-n", "--n-entries=N",
                    Integer,
                    "Analyze N query log entries",
                    "(#{@options[:n_entries]})") do |n|
            @options[:n_entries] = n
          end

          parser.on("--output=PATH",
                    "Output to PATH.",
                    "'-' PATH means standard output.",
                    "(#{@options[:output]})") do |output|
            @options[:output] = output
          end

          parser.on("--input-old-query=PATH",
                    "Use PATH as old input query log or PATH to old query log's directory.",
                    "(#{@options[:input_old_query]})") do |path|
            if File.directory?(path)
              @options[:input_old_query] = Dir.glob("#{path}/*.log")
            elsif File.exist?(path)
              @options[:input_old_query] = [path]
            else
              raise OptionParser::InvalidOption.new("path <#{path}> doesn't exist")
            end
          end

          parser.on("--input-new-query=PATH",
                    "Use PATH as new input query log or PATH to new query log's directory",
                    "(#{@options[:input_new_query]})") do |path|
            if File.directory?(path)
              @options[:input_new_query] = Dir.glob("#{path}/*.log")
            elsif File.exist?(path)
              @options[:input_new_query] = [path]
            else
              raise OptionParser::InvalidOption.new("path <#{path}> doesn't exist")
            end
          end

          parser.on("--slow-operation-ratio=PERCENTAGE",
                    Float,
                    "Use PERCENTAGE% as threshold to detect slow operations.",
                    "Example: --slow-operation-ratio=#{@options[:slow_operation_ratio]} means",
                    "changed amount of operation time is #{@options[:slow_operation_ratio]}% or more.",
                    "(#{@options[:slow_operation_ratio]})") do |ratio|
            @options[:slow_operation_ratio] = ratio
          end

          parser.on("--slow-response-ratio=PERCENTAGE",
                    Float,
                    "Use PERCENTAGE% as threshold to detect slow responses.",
                    "Example: --slow-response-ratio=#{@options[:slow_response_ratio]} means",
                    "changed amount of response time is #{@options[:slow_response_ratio]}% or more.",
                    "(#{@options[:slow_response_ratio]})") do |ratio|
            @options[:slow_response_ratio] = ratio
          end

          parser.on("--slow-operation-threshold=THRESHOLD",
                    Float,
                    "Use THRESHOLD seconds to detect slow operations.",
                    "(#{@options[:slow_operation_threshold]})") do |threshold|
            @options[:slow_operation_threshold] = threshold
          end

          parser.on("--slow-response-threshold=THRESHOLD",
                    Float,
                    "Use THRESHOLD seconds to detect slow responses.",
                    "(#{@options[:slow_response_threshold]})") do |threshold|
            @options[:slow_response_threshold] = threshold
          end
        end
      end

      def group_statistics(old_statistics, new_statistics)
        old_queries = {}
        new_queries = {}
        old_statistics.count.times do |i|
          next if new_statistics.count < old_statistics.count
          next if cached_query?(old_statistics[i])
          next if different_query?(old_statistics[i], new_statistics[i])

          raw_command = old_statistics[i].raw_command
          if old_queries[raw_command]
            statistics = old_queries[raw_command]
            statistics << old_statistics[i]
            old_queries[raw_command] = statistics
          else
            old_queries[raw_command] = [old_statistics[i]]
          end

          if new_queries[raw_command]
            statistics = new_queries[raw_command]
            statistics << new_statistics[i]
            new_queries[raw_command] = statistics
          else
            new_queries[raw_command] = [new_statistics[i]]
          end
        end
        [old_queries, new_queries]
      end

      def analyze(log_paths)
        statistics = GroongaQueryLog::Command::Analyzer::SizedStatistics.new
        statistics.apply_options(@options)
        full_statistics = []
        process_statistic = lambda do |statistic|
          full_statistics << statistic
        end

        begin
          parse(log_paths, &process_statistic)
        rescue Error
          $stderr.puts($!.message)
          return false
        end

        statistics.replace(full_statistics)
        statistics
      end

      def parse(log_paths, &process_statistic)
        parser = Parser.new(@options)
        parse_log(parser, log_paths, &process_statistic)
      end
    end
  end
end