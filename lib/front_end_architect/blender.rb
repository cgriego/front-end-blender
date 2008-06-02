# Copyright (c) 2008 Chris Griego
#           (c) 2008 Blake Elshire
# 
# Blender is freely distributable under the terms of an MIT-style license.
# For details, see http://www.opensource.org/licenses/mit-license.php

require 'rubygems'
require 'yaml'
require 'base64'
require 'benchmark'
require 'mime/types'
require 'find'
require 'pathname'
require 'zlib'

module FrontEndArchitect
  class Blender
    VERSION      = '0.10'
    FILTER_REGEX = /filter: ?[^?]+\(src=(['"])([^?]+)\1,[^?]+\1\);/im
    IMPORT_REGEX = /@import(?: url\(| )(['"])([^?'"]+)\1\)?(?:[^?;]+)?;/im
    URL_REGEX    = /url\((['"]?)([^?'"]+)\1\)/im
    
    DEFAULT_OPTIONS = {
      :blendfile => 'Blendfile.yaml',
      :data      => false,
      :force     => false,
    }
    
    def initialize(opts)
      @options = DEFAULT_OPTIONS.merge(opts)
    end
    
    def blend
      elapsed = Benchmark.realtime do
        unless File.exists? @options[:blendfile]
          raise "Couldn't find '#{@options[:blendfile]}'"
        end
        
        blender = YAML::load_file @options[:blendfile]
        
        Dir.chdir(File.dirname(@options[:blendfile]))
        
        blender = flatten_blendfile(blender)
        
        blender.each do |output_name, sources|
          output_name = Pathname.new(output_name).cleanpath.to_s
          
          output_new       = false
          gzip_output_name = output_name + '.gz'
          
          # Checks the type flag and if the current file meets the type requirements continues
          if output_name.match "." + @options[:file_type].to_s
            file_type = output_name.match(/\.css/) ? "css" : "js"
            
            # Checks if output file exists and checks the mtimes of the source files to the output file if new creates a new file
            if File.exists?(output_name) && (!@options[:gzip] || File.exists?(gzip_output_name))
              output_files = []
              output_files << File.mtime(output_name)
              output_files << File.mtime(gzip_output_name) if @options[:gzip] && File.exists?(gzip_output_name)
              
              oldest_output = output_files.sort.first
              
              sources.each do |i|
                if File.mtime(i) > oldest_output
                  output_new = true
                  break
                end
              end
              
              if output_new || @options[:force]
                create_output(output_name, sources, file_type)
              else
                puts "Skipping: #{output_name}"
                puts "Skipping: #{gzip_output_name}" if @options[:gzip]
              end
            else
              create_output(output_name, sources, file_type)
            end
          end
        end
      end
      
      puts sprintf("%.5f", elapsed) + " seconds"
    end
    
    def generate
      if File.exists?(@options[:blendfile]) && !@options[:force]
        raise "'#{@options[:blendfile]}' already exists"
      end
      
      blend_files = Hash.new
      
      Find.find(Dir.getwd) do |f|
        f.gsub!(Dir.getwd.to_s + "/", "")
        
        if File.extname(f) == ".css"
          file = f.split(".css")
          min_file = file[0] + "-min.css"
          blend_files[min_file] = [f]
        end
        
        if File.extname(f) == ".js"
          file = f.split(".js")
          min_file = file[0] + "-min.js"
          blend_files[min_file] = [f]
        end
        
        Find.prune if File.basename(f).index('.') == 0
      end
      
      blend_files = blend_files.sort
      
      File.open(@options[:blendfile], 'w') do |blendfile|
        blend_files.each do |block|
          blendfile << "#{block[0]}:\r\n  - #{block[1]}\r\n"
        end
      end
    end
    
    protected
    
    def flatten_blendfile(value, key=nil, context=[])
      if value.is_a? Hash
        context << key unless key.nil?
        
        new_hash = {}
        
        value.each do |k, v|
          new_hash.merge! flatten_blendfile(v, k, context.dup)
        end
        
        new_hash
      else
        value.each_index do |i|
          value[i] = (context.join(File::SEPARATOR) + File::SEPARATOR + value[i])
        end
        
        return { (context.join(File::SEPARATOR) + File::SEPARATOR + key) => value }
      end
    end
    
    def create_output(output_name, sources, type)
      output = ''
      
      File.open(output_name, 'w') do |output_file|
        data_sources = []
        
        # Determine full path of the output file
        output_path = Pathname.new(File.expand_path(File.dirname(output_name)))
        
        sources.each do |i|
          # Determine full path of input file
          input_path = Pathname.new(File.dirname(i))
          
          if (File.extname(i) == ".css")
            pre_output = IO.read(i)
            
            pre_output = pre_output.gsub(IMPORT_REGEX) do |import|
              uri = $2
              asset_path = Pathname.new(File.expand_path(uri, File.dirname(i)))
              if (@options[:cache_buster])
                if @options[:cache_buster].empty?
                  buster = File.mtime(asset_path).to_i
                else
                  buster = @options[:cache_buster]
                end
              end
              
              if (output_path != input_path)
                new_path = asset_path.relative_path_from(output_path)
                if (@options[:cache_buster])
                  cache_buster = new_path.to_s+"?#{buster}"
                  puts cache_buster
                  import.gsub!(uri, cache_buster)
                else
                  import.gsub!(uri, new_path)
                end
              else
                if (@options[:cache_buster])
                  cache_buster = asset_path.to_s+"?#{buster}"
                  import.gsub!(uri, cache_buster)
                end
              end
              output.insert(0, import)
              %Q!!
            end
            
            if (output_path == input_path)
              
              if @options[:data]
                pre_output = pre_output.gsub(URL_REGEX) do |uri|
                  new_path = File.expand_path($2, File.dirname(i))
                  %Q!url("#{new_path}")!
                end
              elsif @options[:cache_buster]
                pre_output = pre_output.gsub(URL_REGEX) do
                  uri = $2
                  if (@options[:cache_buster])
                    if @options[:cache_buster].empty?
                      buster = File.mtime(uri).to_i
                    else
                      buster = @options[:cache_buster]
                    end
                    
                    cache_buster = uri.to_s+"?#{buster}"
                  end
                end
              end
              output << pre_output
            else
              # Find all url(.ext) in file and rewrite relative url from output directory.
              pre_output = pre_output.gsub(URL_REGEX) do
                uri = $2
                if @options[:data]
                  # if doing data conversion rewrite url as an absolute path.
                  new_path = File.expand_path(uri, File.dirname(i))
                else
                  asset_path = Pathname.new(File.expand_path(uri, File.dirname(i)))
                  new_path = asset_path.relative_path_from(output_path)
                  if (@options[:cache_buster])
                    if (@options[:cache_buster]).empty?
                      buster = File.mtime(asset_path).to_i
                    else 
                      buster = @options[:cache_buster]
                    end
                    
                    new_path = new_path.to_s+"?#{buster}"
                    puts new_path
                  end
                end
                
                %Q!url("#{new_path}")!
              end
              output << pre_output
            end
          else 
            output << IO.read(i)
          end
        end
        
        # Compress
        libdir = File.join(File.dirname(File.symlink?(__FILE__) ? File.readlink(__FILE__) : __FILE__), *%w[.. .. lib])
        
        IO.popen("java -jar #{libdir}/yui/yuicompressor.jar #{@options[:yuiopts]} --type #{type}", mode="r+") do |io|
          io.write output
          io.close_write
          
          output = io.read
          
          if File.extname(output_name) == ".css"
            output.gsub! ' and(', ' and (' # Workaround for YUI Compressor Bug #1938329
            output.gsub! '*/;}',  '*/}'    # Workaround for YUI Compressor Bug #1961175
            
            if @options[:data]
              output = output.gsub(URL_REGEX) do
                if (!$2.include?(".css"))
                  mime_type    = MIME::Types.type_for($2)
                  url_contents = make_data_uri(IO.read($2), mime_type[0])
                else
                  url_contents = $2
                end
                  %Q!url("#{url_contents}")!
              end
            end
          end
          
          output_file << output
        end
      end
      
      puts output_name
      
      if @options[:gzip]
        output_gzip = output_name + ".gz"
        
        Zlib::GzipWriter.open(output_gzip) do |gz|
          gz.write(output)
        end
        
        puts output_gzip
      end
    end
    
    def make_data_uri(content, content_type)
      "data:#{content_type};base64,#{Base64.encode64(content)}".gsub("\n", '')
    end
  end
end
