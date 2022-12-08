require 'fileutils'
require 'Mkwebook/config'
require 'ferrum'

module Mkwebook
  class App

    attr_accessor :config, :browser, :browser_context, :cli_options

    def initialize(cli_options)
      if cli_options[:work_dir]
        unless File.directory?(cli_options[:work_dir])
          FileUtils.mkdir_p(cli_options[:work_dir])
        end
        Dir.chdir(cli_options[:work_dir])
      end
      @cli_options = cli_options
      @config = Mkwebook::Config.new
    end

    def create_config
      FileUtils.cp(template_config_file, 'mkwebook.yml', verbose: true)
    end

    def template_config_file
      File.join(Mkwebook::GEM_ROOT, 'template', 'mkwebook.yml')
    end

    def make
      prepare_browser
      make_index
      make_pages
    end

    def prepare_browser
      @browser = Ferrum::Browser.new(browser_options)
      @browser_context = browser.contexts.create
    end

    def make_index
      index_page = @browser_context.create_page
      index_page.go_to(@config[:index_page][:url])
      modifier = @config[:index_page][:modifier]
      if modifier && File.file?(modifier)
        index_page.execute(File.read(modifier))
      else
        index_page.execute(modifier) if modifier.present?
      end
      index_elements = index_page.css(@config[:index_page][:selector])

      @page_urls = index_elements.flat_map do |element|
        url = element.css(@config[:index_page][:link_selector]).map { |a| a.evaluate('this.href') }
        element.css(@config[:index_page][:link_selector]).each do |a|
          a.evaluate("this.href = '#{Digest::MD5.hexdigest(a.evaluate('this.href'))}.html'")
        end
        url
      end.uniq

      @page_urls.select! do |url|
        @config[:pages].any? { |page| url =~ Regexp.new(page[:url_pattern]) }
      end

      @page_urls = @page_urls[0, @cli_options[:limit]] if @cli_options[:limit]

      download_assets(index_page, @config[:index_page][:assets] || [])

      index_elements.map do |element|
        element.evaluate('this.outerHTML')
      end.join("\n").tap do |html|
        File.write(@config[:index_page][:output], html)
      end
    end

    def make_pages
      @page_urls.each do |url|
        page_config = @config[:pages].find { |page| url =~ Regexp.new(page[:url_pattern]) }
        next unless page_config
        output = Digest::MD5.hexdigest(url) + '.html'
        page = @browser_context.create_page
        page.go_to(url)
        modifier = page_config[:modifier]
        if modifier && File.file?(modifier)
          page.execute(File.read(modifier))
        else
          page.execute(modifier) if modifier.present?
        end
        page_elements = page.css(page_config[:selector])

        download_assets(page, page_config[:assets] || [])

        page_elements.map do |element|
          element.evaluate('this.outerHTML')
        end.join("\n").tap do |html|
          File.write(output, html)
        end

      end
    end

    def download_assets(page, assets_config)
      assets_config.each do |asset_config|
        asset_attr = asset_config[:attr]
        asset_selector = asset_config[:selector]
        asset_dir = './assets'
        FileUtils.mkdir_p(asset_dir)
        page.css(asset_selector).each do |element|
          asset_url = element.evaluate("this.#{asset_attr}")
          asset_ext_name = File.extname(asset_url)
          asset_file = "#{asset_dir}/#{Digest::MD5.hexdigest(asset_url) + asset_ext_name}"
          page.network.traffic.find { |t| t.url == asset_url }.try do |traffic|
            File.write(asset_file, traffic.response.body)
          end
          element.evaluate("this.#{asset_attr} = '#{asset_file}'")
        end
      end
    end

    private

    def browser_options
      @config[:browser]
    end
  end
end
