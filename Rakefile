require 'csv'
require 'delegate'
require 'securerandom'

require 'active_support/core_ext/hash/except'
require 'hashdiff'
require 'kramdown'
require 'nokogiri'
require 'regexp-examples'

require_relative 'lib/build_node'
require_relative 'lib/table_builder'
require_relative 'lib/xml_base'
require_relative 'lib/xml_builder'

# Modify RegexpExamples to exclude control characters.
# https://github.com/tom-lord/regexp-examples/blob/master/lib/regexp-examples/char_sets.rb
module RegexpExamples
  module CharSets
    def self.redefine(const, value)
      self.send(:remove_const, const)
      self.const_set(const, value)
    end

    redefine(:Any, Any - Control) # libxml2 errors on control characters
    redefine(:AnyNoNewLine, AnyNoNewLine - Control) # libxml2 errors on control characters
    redefine(:Whitespace, Whitespace - ["\f", "\v", "\r", "\n"]) # libxml2 errors on \f and \v, some types restrict \r and \n
    redefine(:BackslashCharMap, BackslashCharMap.merge('s' => Whitespace))
  end
end

def files(glob)
  if ENV['FILES']
    glob = glob.sub('{}', "{#{ENV['FILES']}}")
  else
    glob = glob.sub('{}', '*')
  end
  Dir[glob].sort
end

def pdftotext(path)
  text_path = path.sub(/\.pdf/, '.txt')
  if File.exist?(text_path)
    lines = File.readlines(text_path, chomp: true)
  else
    lines = `pdftotext -layout #{path} -`.split("\n")
  end

  # Remove endnotes.
  lines = lines[0...lines.index{ |line| line['<<HD_reminder>>'] } || -1] + lines[lines.index{ |line| line['<<annex_d1>>'] } || -1...-1]
  # Remove footers.
  lines = lines.reject{ |line| line[/\A<<HD_ln>> <<standardform>> \d+ – <<\S+>> +\d+\z/] }

  lines.join("\n")
end

def label_keys(text)
  text.scan(/<<([^>]+)>>/).flatten
end

def indices(text)
  text.scan(/\b[IV]+(?:\.\d+)*/).flatten
end

def help_text?(key)
  key[/\AHD?_/] || key == 'excl_vat'
end

Dir['tasks/*.rake'].each { |r| import r }
Dir['legacy/*.rake'].each { |r| import r }
