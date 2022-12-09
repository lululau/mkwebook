require 'thor'

module Mkwebook
  class Cli < ::Thor
    class << self
      def main(args)
        start(args)
      end
    end

    class_option :work_dir, :type => :string, :aliases => '-d', :default => '.', :desc => 'Working directory'
    class_option :pause_on_error, :type => :boolean, :aliases => '-e', :default => false, :desc => 'Pause on error, this option will force concurrency off'
    desc 'init', 'Create config file in current directory'
    def init
      Mkwebook::App.new(options).create_config
    end

    option :pause, :type => :boolean, :aliases => '-p', :desc => 'Pause after processing index page'
    desc 'make_index', 'Download and process index page'
    def make_index
      Mkwebook::App.new(options).make_index
    end

    option :limit, :type => :numeric, :aliases => '-l', :desc => 'Limit number of pages, specially for debugging'
    option :pause, :type => :boolean, :aliases => '-P', :desc => 'Pause before quit, this option will force concurrency off'
    option :pause_on_index, :type => :boolean, :aliases => '-p', :desc => 'Pause after processing index page'
    option :single_thread, :type => :boolean, :aliases => '-s', :desc => 'Force conccurency off'
    desc 'make', 'Download and process html files'
    def make
      Mkwebook::App.new(options).make
    end

    desc 'version', 'Print version'
    def version
      puts Mkwebook::VERSION
    end

    no_commands do
    end
  end
end
