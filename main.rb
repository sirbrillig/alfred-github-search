#!/usr/bin/env ruby

app_dir = File.dirname(__FILE__)

# require 'rubygems'
# require 'bundler/setup'
# Directly load gems to speed up start time
$:.unshift File.expand_path("./vendor/bundle/ruby/2.0.0/gems/octokit-3.8.0/lib", app_dir)
$:.unshift File.expand_path("./vendor/bundle/ruby/2.0.0/gems/sawyer-0.6.0/lib", app_dir)
$:.unshift File.expand_path("./vendor/bundle/ruby/2.0.0/gems/faraday-0.9.1/lib", app_dir)
$:.unshift File.expand_path("./vendor/bundle/ruby/2.0.0/gems/addressable-2.3.8/lib", app_dir)
$:.unshift File.expand_path("./vendor/bundle/ruby/2.0.0/gems/multipart-post-2.0.0/lib", app_dir)
require 'octokit'

class AlfredFilterScriptItem
  def initialize( params )
    @params = params
  end

  def to_xml
    %(
<item uid="#{@params[:uid]}" arg="#{@params[:arg]}" autocomplete="#{@params[:autocomplete]}">
  #{tags.join( "\n" )}
</item>
)
  end

  private

  def tags
    [title_tag, subtitle_tag]
  end

  def title_tag
    "<title>#{@params[:title]}</title>" if @params[:title]
  end

  def subtitle_tag
    subtitle_mod = @params[:subtitle_mod] ? " mod=#{@params[:subtitle_mod]}" : ''
    "<subtitle#{subtitle_mod}>#{@params[:subtitle]}</subtitle>" if @params[:subtitle]
  end
end


class AlfredFilterScript
  def initialize
    @items = []
  end

  def add_item( params={} )
    @items << AlfredFilterScriptItem.new( params )
  end

  def to_xml
    if @items.empty?
      '<?xml version="1.0"?><items>' + no_results_item.to_xml + '</items>'
    else
      '<?xml version="1.0"?><items>' + @items.collect do |item|
        item.to_xml
      end.join( '' ) + '</items>'
    end
  end

  private

  def no_results_item
    AlfredFilterScriptItem.new( { title: 'No results found' } )
  end
end

class NoToken < StandardError; end

class CacheFileStore
  attr_accessor :store_hash, :debug

  def initialize(app_dir)
    @store_hash = {}
    @cache_file = '.alfred-gh-workflow-cache'
    @app_dir = app_dir
    load
  end

  def write( key, value )
    debug( "write #{key}" )
    @store_hash[key.to_sym] = value
    save
  end

  def read( key )
    data = @store_hash[key.to_sym]
    if data and not data.empty?
      debug( "read hit #{key}" )
    else
      debug( "read MISS #{key}" )
    end
    data
  end

  def delete( key )
    debug( "delete #{key}" )
    @store_hash[key.to_sym] = nil
  end

  def clear
    debug( "clear cache" )
    @store_hash = {}
    save
  end

  private

  def get_filename
    filename = @cache_file
    filename = File.expand_path( @cache_file, @app_dir ) if @app_dir
    return filename
  end

  def debug( message )
    STDERR.puts( message ) if @debug
  end

  def save
    File.open( get_filename, 'w' ) do |file|
      file.write( Marshal.dump( @store_hash ) )
    end
  end

  def load
    @store_hash = Marshal.load( File.read( get_filename ) ) if File.exists?( get_filename )
  end
end

class Github
  def initialize(app_dir)
    @token = ''
    @logged_in = false
    @token_file = '.alfred-gh-workflow-token'
    @app_dir = app_dir
    @cache = CacheFileStore.new(@app_dir)
  end

  def login
    read_token if ! @token or @token.empty?
    raise NoToken if ! @token or @token.empty?
    @github = Octokit::Client.new( access_token: @token )
    @github.user.login
    @logged_in = true
  end

  def do_search( search_string )
    cached_results = @cache.read( search_string )
    return cached_results if cached_results and not cached_results.empty?
    login unless @logged_in
    # github_search_string = "#{search_string} in:name user:#{user_name}"
    github_search_string = "#{search_string} in:name"
    results = @github.search_repositories( github_search_string, { per_page: 8 } )
    results = prune_results( results.items )
    @cache.write( search_string, results )
    results
  end

  def save_token( token )
    File.open( get_filename, 'w' ) do |file|
      file.write( token )
    end
  end

  def read_token
    @token = File.read( get_filename ).strip if File.exists?( get_filename )
  end

  def clear_cache
    @cache.clear
  end

  private

  def get_filename
    filename = @token_file
    filename = File.expand_path( @token_file, @app_dir ) if @app_dir
    return filename
  end

  def prune_results( results )
    keys = [ :name, :html_url, :description, :full_name, :id ]
    results.collect do |result|
      new_result = {}
      keys.each do |key|
        new_result[key] = result[key]
      end
      new_result
    end
  end

end

search_string = ARGV[0]
raise "You must provide a search string" if ! search_string or search_string.empty?
github = Github.new(app_dir)

if ( search_string == '--auth' )
  begin
    github.save_token( ARGV[1] )
    puts "Token saved"
  rescue
    puts "Saving token failed"
  end
elsif ( search_string == '--expire-cache' )
  begin
    github.clear_cache
    puts "Cleared cache"
  rescue
    puts "Clearing cache failed"
  end
else
  filter = AlfredFilterScript.new
  begin
    results = github.do_search( search_string )
    results.each do |repo|
      filter.add_item( {
        title: repo[:name],
        autocomplete: repo[:name],
        arg: repo[:html_url],
        subtitle: repo[:description],
        uid: repo[:id]
      } )
    end
  rescue NoToken
    filter.add_item( { title: 'No token set', subtitle: 'Generate a new token, then save it by using gh-auth', arg: 'https://github.com/settings/tokens/new' } )
  rescue Octokit::Unauthorized
    filter.add_item( { title: 'Invalid token', subtitle: 'Generate a new token, then save it by using gh-auth', arg: 'https://github.com/settings/tokens/new' } )
  end
  puts filter.to_xml
end
