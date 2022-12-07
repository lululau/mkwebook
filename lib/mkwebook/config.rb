require 'delegate'
require 'etc'

module Mkwebook
  class Config < SimpleDelegator
    attr_accessor :file, :config

    def initialize(file = nil)
      super(nil)
      @file = file || find_mkwebook_yaml
      if @file && File.exist?(@file)
        @config = load(@file)
        __setobj__(@config)
      else
        __setobj__(self)
      end
    end

    def load(config_file)
      default_config = {
        "browser" => {
          "headless" => true
        },
        "concurrency" => Etc.nprocessors
      }
      config = YAML.load_file(config_file)
      default_config.deep_merge(config).deep_transform_keys! { |k| k.to_s.underscore.to_sym }
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

# Ruby 获取 CPU 个数
def cpu_count
  if RUBY_PLATFORM =~ /linux/
    `cat /proc/cpuinfo | grep processor | wc -l`.to_i
  elsif RUBY_PLATFORM =~ /darwin/
    `sysctl -n hw.ncpu`.to_i
  else
    1
  end
end
