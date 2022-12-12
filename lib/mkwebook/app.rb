require 'fileutils'
require 'Mkwebook/config'
require 'ferrum'
require 'pry-byebug'
require 'concurrent'

module Mkwebook
  class App
    attr_accessor :config, :browser, :browser_context, :cli_options

    def initialize(cli_options)
      if cli_options[:work_dir]
        FileUtils.mkdir_p(cli_options[:work_dir]) unless File.directory?(cli_options[:work_dir])
        Dir.chdir(cli_options[:work_dir])
      end
      @cli_options = cli_options
      @config = Mkwebook::Config.new(@cli_options[:pause] || @cli_options[:pause_on_error] || @cli_options[:single_thread])
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
      set_auth_info if @config.authentication?
    end

    def set_auth_info
      page = @browser_context.create_page
      page.go_to(@config[:authentication][:url])
      if @config[:authentication][:cookies]
        page.execute("document.cookie = '#{@config[:authentication][:cookies]}'")
      end

      if @config[:authentication][:local_storage]
        @config[:authentication][:local_storage].each do |key, value|
          page.execute("localStorage.setItem('#{key}', '#{value}')")
        end
      end
    end

    def make_index
      prepare_browser
      index_page = @browser_context.create_page
      index_page.go_to(@config[:index_page][:url])
      index_page.network.wait_for_idle(timeout: 10) rescue nil
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


      @config[:index_page][:title].try do |title|
        index_page.execute("document.title = '#{title}'")
      end

      index_page.execute <<-JS
        for (var e of document.querySelectorAll('[integrity]')) {
          e.removeAttribute('integrity');
        }
      JS

      binding.pry if @cli_options[:pause]
      download_assets(index_page, @config[:index_page][:assets] || [], @config[:index_page][:output])

      index_elements.map do |element|
        element.evaluate('this.outerHTML')
      end.join("\n").tap do |html|
        File.write(@config[:index_page][:output], html)
      end
    rescue Ferrum::Error => e
      binding.pry
    end

    def make_pages

      pool = Concurrent::FixedThreadPool.new(@config[:concurrency])

      @page_urls.each do |url|
        page_config = @config[:pages].find { |page| url =~ Regexp.new(page[:url_pattern]) }
        next unless page_config

        pool.post do
          page = @browser_context.create_page

          begin
            output = url.normalize_file_path('.html')
            page.go_to(url)
            page.network.wait_for_idle(timeout: 10) rescue nil
            modifier = page_config[:modifier]
            if modifier && File.file?(modifier)
              page.execute(File.read(modifier))
            elsif modifier.present?
              page.execute(modifier)
            end
            page_elements = page.css(page_config[:selector])

            @config[:index_page][:title].try do |title|
              page.execute("document.title = '#{title}'")
            end

            page.execute <<-JS
              for (var e of document.querySelectorAll('[integrity]')) {
                  e.removeAttribute('integrity');
              }
            JS

            binding.pry if @cli_options[:pause]
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
              FileUtils.mkdir_p(File.dirname(output))
              File.write(output, html)
            end
          rescue Ferrum::Error => e
            $stderr.puts e.message
            $stderr.puts e.backtrace
            binding.pry if @cli_options[:pause_on_error]
          ensure
            page.close
          end
        end

      end

      pool.shutdown
      pool.wait_for_termination
    end

    def download_assets(page, assets_config, page_uri = nil)
      assets_config.each do |asset_config|
        asset_attr = asset_config[:attr]
        asset_selector = asset_config[:selector]
        page.css(asset_selector).each do |element|
          asset_url = element.evaluate("this.#{asset_attr}")
          next if asset_url.start_with?('data:')
          asset_file = asset_url.normalize_file_path
          FileUtils.mkdir_p(File.dirname(asset_file))
          page.network.traffic.find { |t| t.url == asset_url }.try do |traffic|
            traffic&.response&.body.try do |body|
              File.write(asset_file, body)
            end
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
