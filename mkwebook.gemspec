require_relative 'lib/mkwebook/version'

Gem::Specification.new do |spec|
  spec.name          = "mkwebook"
  spec.version       = Mkwebook::VERSION
  spec.authors       = ["Liu Xiang"]
  spec.email         = ["liuxiang921@gmail.com"]

  spec.summary       = %{A tool to download web pages and convert them to Calibre ready.}
  spec.description   = %{A tool to download web pages and convert them to Calibre ready.}
  spec.homepage      = "https://github.com/lululau/mkwebook"
  spec.license       = "MIT"
  spec.required_ruby_version = Gem::Requirement.new(">= 2.6.0")



  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files         = Dir.chdir(File.expand_path('..', __FILE__)) do
    `git ls-files -z`.split("\x0").reject { |f| f.match(%r{^(test|spec|features)/}) }
  end
  spec.bindir        = "exe"
  spec.executables   = spec.files.grep(%r{^exe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency 'activesupport', '>= 6.1.5'

  spec.add_development_dependency 'pry', '~> 0.13.1'
  spec.add_development_dependency 'pry-byebug', '~> 3.9.0'
end
