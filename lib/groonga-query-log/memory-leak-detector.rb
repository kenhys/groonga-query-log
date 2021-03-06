# Copyright (C) 2013-2017  Kouhei Sutou <kou@clear-code.com>
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

require "time"

require "groonga/client"

require "groonga-query-log/parser"

module GroongaQueryLog
    class MemoryLeakDetector
      def initialize(options)
        @options = options
      end

      def detect(input)
        each_command(input) do |command|
          @options.create_client do |client|
            begin
              check_command(client, command)
            rescue Groonga::Client::Connection::Error
              # TODO: add error log mechanism
              $stderr.puts(Time.now.iso8601(6))
              $stderr.puts(command.original_source)
              $stderr.puts($!.raw_error.message)
              $stderr.puts($!.raw_error.backtrace)
            end
          end
        end
      end

      private
      def each_command(input)
        parser = Parser.new
        parser.parse(input) do |statistic|
          yield(statistic.command)
        end
      end

      def check_command(client, command)
        command["cache"] = "no" if @options.force_disable_cache?
        current_n_allocations = nil
        @options.n_tries.times do |i|
          client.execute(command)
          previous_n_allocations = current_n_allocations
          current_n_allocations = n_allocations(client)
          next if previous_n_allocations.nil?
          if current_n_allocations > previous_n_allocations
            max_n_digits = [
              compute_n_digits(previous_n_allocations),
              compute_n_digits(current_n_allocations),
            ].max
            puts("detect a memory leak:")
            puts("Nth try: #{i}")
            puts("previous: %*d" % [max_n_digits, previous_n_allocations])
            puts(" current: %*d" % [max_n_digits, current_n_allocations])
            puts(command.original_source)
          end
        end
      end

      def n_allocations(client)
        client.status.n_allocations
      end

      def compute_n_digits(n)
        (Math.log10(n) + 1).floor
      end

      class Options
        attr_accessor :host
        attr_accessor :port
        attr_accessor :protocol
        attr_accessor :pid
        attr_accessor :n_tries
        attr_writer :force_disable_cache
        def initialize
          @host = "127.0.0.1"
          @port = 10041
          @protocol = :gqtp
          @pid = guess_groonga_server_pid
          @n_tries = 10
          @force_disable_cache = true
        end

        def force_disable_cache?
          @force_disable_cache
        end

        def create_client(&block)
          Groonga::Client.open(:host     => @host,
                               :port     => @port,
                               :protocol => @protocol,
                               &block)
        end

        private
        def guess_groonga_server_pid
          # This command line works only for ps by procps.
          pid = `ps -o pid --no-header -C groonga`.strip
          if pid.empty?
            nil
          else
            pid.to_i
          end
        end
      end
    end
end
