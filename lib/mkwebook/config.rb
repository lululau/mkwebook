require 'delegate'
require 'etc'

module Mkwebook
  class Config < SimpleDelegator
    attr_accessor :file, :config, :cli_options

    def initialize(cli_options = {})
      super(nil)
      @cli_options = cli_options
      @file = find_mkwebook_yaml
      if @file && File.exist?(@file)
        @config = load(@file)
        __setobj__(@config)
      else
        __setobj__(self)
      end
    end

    def load(config_file)
      default_config = {
        'browser' => {
          'headless' => true,
        },
        'concurrency': 1
      }
      config = YAML.load_file(config_file)
      config = default_config.deep_merge(config).deep_transform_keys! { |k| k.to_s.underscore.to_sym }
      config[:concurrency] = 1 if force_single_threaded?
      @cli_options[:headless].try do |headless|
        config[:browser][:headless] = headless
      end
      config
    end

    def concurrent?
      config[:concurrency].present?
    end

    def authentication?
      config.dig(:authentication, :cookies).present? || config.dig(:authentication, :local_storage).present?
    end

    def find_mkwebook_yaml
      dir = Dir.pwd
      while dir != '/'
        file = File.join(dir, 'mkwebook.yaml')
        return file if File.exist?(file)

        file = File.join(dir, 'mkwebook.yml')
        return file if File.exist?(file)

        dir = File.dirname(dir)
      end
    end

    def force_single_threaded?
      @cli_options[:pause] || @cli_options[:pause_on_error] || @cli_options[:single_thread]
    end
  end
end
