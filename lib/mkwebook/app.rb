require 'fileutils'
require 'sqlite3'
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
      @config = Mkwebook::Config.new(@cli_options)
      @downloaded_depth = 0
      @downloaded_files = []
    end

    def create_config
      FileUtils.cp(template_config_file, 'mkwebook.yml', verbose: true)
    end

    def template_config_file
      File.join(Mkwebook::GEM_ROOT, 'template', 'mkwebook.yml')
    end

    def download
      download_index
      append_extra_pages
      download_pages
      modify_page_links
      post_process
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

    def download_index(only_index = false)
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
          u = a.evaluate('this.href')
          href = u.normalize_uri('.html').relative_path_from(@config[:index_page][:output])
          file = @config[:index_page][:output]
          a.evaluate <<~JS
            (function() {
              this.setAttribute('data-mkwebook-href', #{href});
              this.setAttribute('data-mkwebook-file', #{file});
            })();
          JS
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
      @downloaded_files << @config[:index_page][:output]
      modify_page_links if only_index
    rescue Ferrum::Error => e
      binding.pry
    end

    def download_pages
      return unless @downloaded_depth < @config[:max_recursion]

      pool = Concurrent::FixedThreadPool.new(@config[:concurrency])

      @page_links = @page_urls.map { |url| [url, []] }.to_h

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

            if page_link_selector = page_config[:page_link_selector]
              page_links = page_elements.flat_map do |element|
                element.css(page_link_selector).map { |a| a.evaluate('this.href') }
              end.uniq
              @page_links[url] = page_links
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
                href = u.normalize_uri('.html').relative_path_from(url.normalize_uri('.html'))
                file = u.normalize_file_path('.html')
                a.evaluate <<~JS
                  (function() {
                      this.setAttribute('data-mkwebook-href', #{href});
                      this.setAttribute('data-mkwebook-file', #{file});
                  })();
                JS
              end
              element.evaluate('this.outerHTML')
            end.join("\n").tap do |html|
              FileUtils.mkdir_p(File.dirname(output))
              File.write(output, html)
            end

            @downloaded_files << output
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

      @page_urls = @page_links.flat_map(&:last).uniq
      @downloaded_depth += 1
      download_pages
    end

    def post_process
      @config[:post_process].try do |script|
        if File.file?(script)
          system(script)
        else
          system('bash', '-c', script)
        end
      end
    end

    def append_extra_pages
      @config[:extra_pages]&.each do |url|
        @page_urls << url
      end
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

    def make_docset
      docset_config = @config[:docset]
      docset_name = "#{docset_config[:name]}.docset"
      doc_path = "#{docset_name}/Contents/Resources/Documents"
      dsidx_path = "#{docset_name}/Contents/Resources/docSet.dsidx"
      icon_path = "#{docset_name}/icon.png"
      info = "#{docset_name}/Contents/info.plist"

      if Dir.exist?(docset_name)
        puts 'Docset directory already exist!'
      else
        FileUtils.mkdir_p(doc_path)
        puts "Create the docset directory!"
      end

      # Copy files
      FileUtils.cp_r(Dir.glob("*") - [docset_name], doc_path)
      puts 'Copy the HTML documentations!'

      # Init SQLite

      FileUtils.rm_f(dsidx_path)
      db = SQLite3::Database.new(dsidx_path)
      db.execute <<-SQL
      CREATE TABLE searchIndex(id INTEGER PRIMARY KEY, name TEXT, type TEXT, path TEXT);
      SQL
      db.execute <<-SQL
      CREATE UNIQUE INDEX anchor ON searchIndex (name, type, path);
      SQL
      puts 'Create the SQLite Index'

      pages = Dir.glob("#{doc_path}/**/*.html").select do |file|
        docset_config[:pages].find { |page| file =~ Regexp.new(page[:url_pattern]) }
      end

      pages = pages[0, @cli_options[:limit]] if @cli_options[:limit]

      prepare_browser

      page = @browser_context.create_page

      elements = pages.flat_map do |file|
        begin
          page.go_to("file://#{File.expand_path(file)}")
          page_config = docset_config[:pages].find { |page| file =~ Regexp.new(page[:url_pattern]) }
          page.evaluate(page_config[:extractor]) || []
        rescue => e
          puts e.message
          puts e.backtrace
        end
      end

      elements.uniq.compact.each do |element|
        name = element['name']
        type = element['type']
        path = element['path'].sub(%r{.*\.docset/Contents/Resources/Documents}, '')
        db.execute('INSERT OR IGNORE INTO searchIndex(name, type, path) VALUES (?, ?, ?);', [name, type, path])
      end

      plist_content = <<-PLIST
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
                <key>CFBundleIdentifier</key>
                <string>#{docset_name.sub(/.docset/, '')}</string>
                <key>CFBundleName</key>
                <string>#{docset_name.sub(/.docset/, '')}</string>
                <key>DashDocSetFamily</key>
                <string>#{docset_name.sub(/.docset/, '')}</string>
                <key>DocSetPlatformFamily</key>
                <string>#{docset_config[:keyword] || docset_name.downcaseload.sub(/.docset/, '')}</string>
                <key>isDashDocset</key>
                <true/>
                <key>isJavaScriptEnabled</key>
                <true/>
                <key>dashIndexFilePath</key>
                <string>#{docset_config[:index]}</string>
        </dict>
        </plist>
      PLIST
      File.open(info, 'w') { |f| f.write(plist_content)}

      # Add icon
      if docset_config[:icon]
        if docset_config[:icon].end_with?('.png')
          FileUtils.cp(docset_config[:icon], icon_path)
          puts 'Create the icon for docset!'
        else
          puts '**Error**: icon file should be a valid PNG image!'
          exit(2)
        end
      end
    end

    def list_entry_types
      puts IO.read("#{__dir__}/entry_types.txt")
    end

    def modify_page_links
      pool = Concurrent::FixedThreadPool.new(@config[:concurrency])
      @downloaded_files.each do |file|
        pool.post do
          begin
            page = @browser_context.create_page
            page.go_to("file://#{File.expand_path(file)}")
            page.css('a').each do |a|
              href = a.evaluate('this.getAttribute("data-mkwebook-href")')
              f = a.evaluate('this.getAttribute("data-mkwebook-file")')
              next unless href && f && @downloaded_files.include?(f)
              a.evaluate("this.href = '#{href}'")
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

    private

    def browser_options
      @config[:browser]
    end
  end
end
