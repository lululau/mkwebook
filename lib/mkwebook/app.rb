require 'fileutils'
require 'Mkwebook/config'
require 'ferrum'

module Mkwebook
  class App
    attr_accessor :config, :browser, :browser_context, :cli_options

    def initialize(cli_options)
      if cli_options[:work_dir]
        FileUtils.mkdir_p(cli_options[:work_dir]) unless File.directory?(cli_options[:work_dir])
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
      make_index
      make_pages
    end

    def prepare_browser
      @browser = Ferrum::Browser.new(browser_options)
      @browser_context = browser.contexts.create
    end

    def make_index
      prepare_browser
      index_page = @browser_context.create_page
      index_page.go_to(@config[:index_page][:url])
      modifier = @config[:index_page][:modifier]
      if modifier && File.file?(modifier)
        index_page.execute(File.read(modifier))
      elsif modifier.present?
        index_page.execute(modifier)
      end
      index_elements = index_page.css(@config[:index_page][:selector])

      @page_urls = index_elements.flat_map do |element|
        url = element.css(@config[:index_page][:link_selector]).map { |a| a.evaluate('this.href') }
        element.css(@config[:index_page][:link_selector]).each do |a|
          u = a.evaluate('this.href').normalize_uri('.html').relative_path_from(@config[:index_page][:output])
          a.evaluate("this.href = '#{u}'")
        end
        url
      end.uniq

      @page_urls.select! do |url|
        @config[:pages].any? { |page| url =~ Regexp.new(page[:url_pattern]) }
      end

      @page_urls = @page_urls[0, @cli_options[:limit]] if @cli_options[:limit]

      download_assets(index_page, @config[:index_page][:assets] || [], @config[:index_page][:output])

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

        output = url.normalize_file_path('.html')
        page = @browser_context.create_page
        page.go_to(url)
        modifier = page_config[:modifier]
        if modifier && File.file?(modifier)
          page.execute(File.read(modifier))
        elsif modifier.present?
          page.execute(modifier)
        end
        page_elements = page.css(page_config[:selector])

        download_assets(page, page_config[:assets] || [])

        page_elements.map do |element|
          element.css('a').each do |a|
            u = a.evaluate('this.href')
            next unless @page_urls.include?(u)

            u = u.normalize_uri('.html').relative_path_from(url.normalize_uri('.html'))
            a.evaluate("this.href = '#{u}'")
          end
          element.evaluate('this.outerHTML')
        end.join("\n").tap do |html|
          File.write(output, html)
        end
      end
    end

    def download_assets(page, assets_config, page_uri = nil)
      assets_config.each do |asset_config|
        asset_attr = asset_config[:attr]
        asset_selector = asset_config[:selector]
        page.css(asset_selector).each do |element|
          asset_url = element.evaluate("this.#{asset_attr}")
          asset_file = asset_url.normalize_file_path
          FileUtils.mkdir_p(File.dirname(asset_file))
          page.network.traffic.find { |t| t.url == asset_url }.try do |traffic|
            File.write(asset_file, traffic.response.body)
          end
          u = asset_url.normalize_uri.relative_path_from((page_uri || page.url.normalize_uri))
          element.evaluate("this.#{asset_attr} = '#{u}'")
        end
      end
    end

    private

    def browser_options
      @config[:browser]
    end
  end
end
