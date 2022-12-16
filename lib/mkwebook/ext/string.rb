require 'uri'

class String
  def p
    puts self
  end

  def expa
    File.expand_path(self)
  end

  def f
    expa
  end

  def normalize_file_path(force_extname = nil)
    return self unless present?
    uri = URI.parse(self)
    return unless uri.scheme.in? %w(http https)
    return unless uri.path.present?
    file_path = uri.path[1..]
    extname = force_extname || File.extname(file_path)
    basename = File.basename(file_path, extname)
    origin = "#{uri.scheme.try { |s| s + '_' }}#{uri.host}#{uri.port.try { |p| '_' + p.to_s }}"
    basename += "_#{Digest::MD5.hexdigest(uri.query)}" if uri.query.present?
    URI.decode_www_form_component(File.join(origin, File.dirname(file_path), basename + extname))
  end

  def normalize_uri(force_extname = nil)
    return self unless present?
    uri = URI.parse(self)
    return unless uri.scheme.in? %w(http https)
    return unless uri.path.present?
    file_path = uri.path[1..]
    extname = force_extname || File.extname(file_path)
    basename = File.basename(file_path, extname)
    basename += "_#{Digest::MD5.hexdigest(uri.query)}" if uri.query.present?
    origin = "#{uri.scheme.try { |s| s + '_' }}#{uri.host}#{uri.port.try { |p| '_' + p.to_s }}"
    file_path = File.join(origin, File.dirname(file_path), basename + extname)
    if uri.fragment.present?
      file_path += "##{uri.fragment}"
    else
      file_path
    end
  end

  def relative_path_from(base)
    Pathname.new(self).relative_path_from(Pathname.new(base)).to_s.gsub(%r{^\.\./}, '')
  end
end
