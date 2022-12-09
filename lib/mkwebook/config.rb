require 'delegate'
require 'etc'

module Mkwebook
  class Config < SimpleDelegator
    attr_accessor :file, :config

    def initialize(force_concurrency_off)
      super(nil)
      @file = find_mkwebook_yaml
      if @file && File.exist?(@file)
        @config = load(@file, force_concurrency_off)
        __setobj__(@config)
      else
        __setobj__(self)
      end
    end

    def load(config_file, force_concurrency_off)
      default_config = {
        'browser' => {
          'headless' => true
        },
        'concurrency': 1
      }
      config = YAML.load_file(config_file)
      config = default_config.deep_merge(config).deep_transform_keys! { |k| k.to_s.underscore.to_sym }
      config[:concurrency] = 1 if force_concurrency_off
      config
    end

    def concurrent?
      config[:concurrency].present?
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
  end
end
