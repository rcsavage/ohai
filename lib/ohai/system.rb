#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2008 Opscode, Inc.
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require 'ohai/loader'
require 'ohai/log'
require 'ohai/mash'
require 'ohai/runner'
require 'ohai/dsl'
require 'ohai/mixin/from_file'
require 'ohai/mixin/command'
require 'ohai/mixin/os'
require 'ohai/mixin/string'
require 'ohai/provides_map'
require 'ohai/hints'
require 'mixlib/shellout'

require 'yajl'

module Ohai

  class System
    attr_accessor :data
    attr_reader :provides_map
    attr_reader :v6_dependency_solver

    def initialize
      @data = Mash.new
      @provides_map = ProvidesMap.new

      @v6_dependency_solver = Hash.new
      @plugin_path = ""

      @loader = Ohai::Loader.new(self)
      @runner = Ohai::Runner.new(self, true)

      Ohai::Hints.refresh_hints()
    end

    def [](key)
      @data[key]
    end

    #=============================================
    #  Version 7 system commands
    #=============================================
    def all_plugins
      load_plugins
      run_plugins(true)
    end

    def load_plugins
      Ohai::Config[:plugin_path].each do |path|
        Dir[File.join(path, '**', '*.rb')].each do |plugin_file_path|
          # Load all the *.rb files under the configured paths in :plugin_path
          plugin = @loader.load_plugin(plugin_file_path)

          if plugin && plugin.version == :version6
            # Capture the plugin in @v6_dependency_solver if it is a V6 plugin
            # to be able to resolve V6 dependencies later on.
            partial_path = Pathname.new(plugin_file_path).relative_path_from(Pathname.new(path)).to_s
            dep_solver_key = nameify_v6_plugin(partial_path)

            unless @v6_dependency_solver.has_key?(dep_solver_key)
              @v6_dependency_solver[dep_solver_key] = plugin
            else
              Ohai::Log.debug("Plugin '#{plugin_file_path}' is already loaded.")
            end
          end
        end
      end
    end
    
    def run_plugins(safe = false, force = false)
      # collect and run version 6 plugins
      v6plugins = []
      @v6_dependency_solver.each { |plugin_name, plugin| v6plugins << plugin if plugin.version.eql?(:version6) }
      v6plugins.each do |v6plugin|
        if !v6plugin.has_run? || force
          safe ? v6plugin.safe_run : v6plugin.run
        end
      end

      # collect and run version 7 plugins
      plugins = @provides_map.all_plugins

      begin
        plugins.each { |plugin| @runner.run_plugin(plugin, force) }
      rescue Ohai::Exceptions::AttributeNotFound, Ohai::Exceptions::DependencyCycle => e
        Ohai::Log.error("Encountered error while running plugins: #{e.inspect}")
        raise
      end
      true
    end

    def collect_plugins(plugins)
      collected = []
      if plugins.is_a?(Mash)
        # TODO: remove this branch
        plugins.keys.each do |plugin|
          if plugin.eql?("_plugins")
            collected << plugins[plugin]
          else
            collected << collect_plugins(plugins[plugin])
          end
        end
      else
        collected << plugins
      end
      collected.flatten.uniq
    end

    #=============================================
    # Version 6 system commands
    #=============================================
    def require_plugin(plugin_name, force=false)
      unless force
        plugin = @v6_dependency_solver[plugin_name]
        return true if plugin && plugin.has_run?
      end

      if Ohai::Config[:disabled_plugins].include?(plugin_name)
        Ohai::Log.debug("Skipping disabled plugin #{plugin_name}")
        return false
      end

      if plugin = @v6_dependency_solver[plugin_name] or plugin = plugin_for(plugin_name)
        begin
          plugin.version.eql?(:version7) ? @runner.run_plugin(plugin, force) : plugin.safe_run
          true
        rescue SystemExit, Interrupt
          raise
        rescue DependencyCycleError, NoAttributeError => e
          Ohai::Log.error("Encountered error while running plugins: #{e.inspect}")
          raise
        rescue Exception,Errno::ENOENT => e
          Ohai::Log.debug("Plugin #{plugin_name} threw exception #{e.inspect} #{e.backtrace.join("\n")}")
        end
      else
        Ohai::Log.debug("No #{plugin_name} found in #{Ohai::Config[:plugin_path]}")
      end
    end

    def plugin_for(plugin_name)
      filename = "#{plugin_name.gsub("::", File::SEPARATOR)}.rb"

      plugin = nil
      Ohai::Config[:plugin_path].each do |path|
        check_path = File.expand_path(File.join(path, filename))
        if File.exist?(check_path)
          plugin = @loader.load_plugin(check_path)
          @v6_dependency_solver[plugin_name] = plugin
          break
        else
          next
        end
      end
      plugin
    end

    # todo: fix for running w/new internals
    # add updated function to v7?
    def refresh_plugins(path = '/')
      Ohai::Hints.refresh_hints()

      parts = path.split('/')
      if parts.length == 0
        h = @metadata
      else
        parts.shift if parts[0].length == 0
        h = @metadata
        parts.each do |part|
          break unless h.has_key?(part)
          h = h[part]
        end
      end

      refreshments = collect_plugins(h)
      Ohai::Log.debug("Refreshing plugins: #{refreshments.join(", ")}")

      refreshments.each do |r|
        @seen_plugins.delete(r) if @seen_plugins.has_key?(r)
      end
      refreshments.each do |r|
        require_plugin(r) unless @seen_plugins.has_key?(r)
      end
    end

    #=============================================
    # For outputting an Ohai::System object
    #=============================================
    # Serialize this object as a hash
    def to_json
      Yajl::Encoder.new.encode(@data)
    end

    # Pretty Print this object as JSON
    def json_pretty_print(item=nil)
      Yajl::Encoder.new(:pretty => true).encode(item || @data)
    end

    def attributes_print(a)
      data = @data
      a.split("/").each do |part|
        data = data[part]
      end
      raise ArgumentError, "I cannot find an attribute named #{a}!" if data.nil?
      case data
      when Hash,Mash,Array,Fixnum
        json_pretty_print(data)
      when String
        if data.respond_to?(:lines)
          json_pretty_print(data.lines.to_a)
        else
          json_pretty_print(data.to_a)
        end
      else
        raise ArgumentError, "I can only generate JSON for Hashes, Mashes, Arrays and Strings. You fed me a #{data.class}!"
      end
    end

    def nameify_v6_plugin(partial_path)
      md = Regexp.new("(.+).rb$").match(partial_path)
      md[1].gsub(File::SEPARATOR, "::")
    end

  end
end
