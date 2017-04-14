#!/usr/bin/ruby
# -*- coding: utf-8 -*-
# frozen_string_literal: true
require 'fileutils'
require 'json'
require 'logger'
require 'net/http'
require 'open-uri'
require 'optparse'
require 'pathname'
require 'time'
require 'uri'

class MastodonLogger
  def initialize(url, logger = nil)
    @uri = URI(url)
    dir = Pathname("data/#{uri.hostname}")
    @logger = logger || Logger.new(STDERR)
    @store = JsonStore.new(dir, @logger)
  end

  attr_reader :uri
  attr_reader :store
  attr_reader :logger

  PROG_NAME = 'MastodonLogger'

  class JsonStore
    def initialize(dir, logger)
      @cache = {}
      @dir = dir
      @logger = logger
    end

    attr_reader :dir
    attr_reader :logger

    def read(key, path = dir + "#{key}.json")
      path = dir + "#{key}.json"
      logger.debug(PROG_NAME) { "Store read #{path}" }
      @cache[key] = JSON.parse(path.read)
    end

    def write(key, value, options = {})
      path = dir + "#{key}.json"
      logger.debug(PROG_NAME) { "Store write #{path}" }
      path.dirname.mkpath
      path.write(value.to_json, options)
      @cache[key] = value
    end

    def safe(key)
      return @cache[key] if @cache.key?(key)
      begin
        read(key)
      rescue Errno::ENOENT
        write(key, yield, perm: 0600)
      end
      @cache[key]
    end

    def [](key)
      return @cache[key] if @cache.key?(key)
      path = dir + "#{key}.json"
      if path.exist?
        read(key, path)
      end
      @cache[key]
    end

    def []=(key, value)
      write(key, value)
      if value.nil?
        @cache.delete(key)
      end
    end
  end

  def fatal(message)
    logger.fatal(PROG_NAME) { message }
    raise message
  end

  def cred
    store.safe('cred') do
      logger.info(PROG_NAME) { 'Create apps' }
      res = Net::HTTP.post_form(uri + '/api/v1/apps', {
        client_name: 'mastodon-logger',
        redirect_uris: 'urn:ietf:wg:oauth:2.0:oob',
        scopes: 'read',
        website: 'https://github.com/znz/mastodon-logger',
      })
      logger.debug(PROG_NAME) { "Response body: #{res.body}" }
      if res.content_type != 'application/json'
        fatal "Invalid response type: #{res.content_type}; body: #{res.body.dump}"
      end
      cred = JSON.parse(res.body)
      unless cred['client_id'] && cred['client_secret']
        fatal "Invalid response body: #{res.body.dump}"
      end
      cred
    end
  end

  def auth
    store.safe('auth') do
      cred # create
      STDERR.print 'Input your email: '
      user = gets.chomp
      STDERR.print 'Input your password: '
      pass = gets.chomp
      logger.info(PROG_NAME) { "Create oauth token by #{user}" }
      res = Net::HTTP.post_form(uri + '/oauth/token', {
        client_id: cred['client_id'],
        client_secret: cred['client_secret'],
        grant_type: 'password',
        username: user,
        password: pass,
      })
      logger.debug(PROG_NAME) { "Response body: #{res.body}" }
      if res.content_type != 'application/json'
        fatal "Invalid response type: #{res.content_type}; body: #{res.body.dump}"
      end
      auth = JSON.parse(res.body)
      unless auth['access_token']
        fatal "Invalid response body: #{res.body.dump}"
      end
      auth
    end
  end

  def get(uri, header = { 'Authorization' => "Bearer #{auth['access_token']}" })
    logger.debug(PROG_NAME) { "GET #{uri}" }
    header['User-Agent'] ||= 'MastodonLogger/0.0.0'
    open(uri, header) do |io|
      body = io.read
      meta = io.meta
      logger.debug(PROG_NAME) do
        h = {
          'X-RateLimit-Limit'     => meta['x-ratelimit-limit'],
          'X-RateLimit-Remaining' => meta['x-ratelimit-remaining'],
          'X-RateLimit-Reset'     => meta['x-ratelimit-reset'],
          'Content-Type'          => meta['content-type'],
          'Link'                  => meta['link'],
        }
        "#{io.status.join(' ')} #{h.to_json}"
      end
      if io.content_type != 'application/json'
        fatal "Invalid response type: #{meta.content_type}; body: #{body.dump}"
      end
      if io.status[0] != '200'
        fatal "Invalid response: #{body.dump}"
      end
      if meta['x-ratelimit-remaining'] && meta['x-ratelimit-reset']
        store['cache/ratelimit'] = {
          'limit'     => meta['x-ratelimit-limit'],
          'remaining' => meta['x-ratelimit-remaining'],
          'reset'     => meta['x-ratelimit-reset'],
        }
      end
      yield body, meta
    end
  end

  def wait_ratelimit
    ratelimit = store['cache/ratelimit']
    if ratelimit && ratelimit['remaining'] && ratelimit['reset']
      remaining = ratelimit['remaining']
      reset = ratelimit['reset']
      reset = Time.parse(reset)
      now = Time.now
      remaining = remaining.to_i
      wait_time = (reset - now) / remaining
      if wait_time > 0
        logger.info(PROG_NAME) { "Wait until #{now + wait_time} (reset: #{reset}, remaining: #{remaining})" }
        sleep wait_time
      end
    end
  rescue ArgumentError
    # ignore
  end

  def parse_link(link)
    links = {}
    link.scan(/<(.+?)>; rel="(.+?)"/) do |uri, rel|
      links[rel] = uri
    end
    links
  end

  def save_account(account)
    return unless account
    if account.key?('id')
      store["account/#{account['id']}"] = account
    else
      logger.warn(PROG_NAME) do
        "Ignore invalid account: #{account.to_json}"
      end
    end
  end

  def save_status(status)
    return unless status
    logger.info(PROG_NAME) do
      account = status['account'] || {}
      "Save status: #{status['id']} #{status['created_at']} #{account['username']} #{status['content']}"
    end
    if status.key?('id') && status.key?('created_at')
      date = status['created_at'][/\A\d+-\d+-\d+/]
      store["status/#{date}/#{status['id']}"] = status
      if status.key?('account')
        save_account(status['account'])
      end
    else
      logger.warn(PROG_NAME) do
        "Ignore invalid status: #{status.to_json}"
      end
    end
  end

  def timelines(path, link_type = 'prev')
    link_cache_key = "cache/link-#{link_type}/#{path}"
    link = store[link_cache_key]
    if link && link[link_type]
      if link_type == 'next' && link['last_get'] == link[link_type]
        # oldest
        logger.warn(PROG_NAME) { "Skip because no more next of #{link['last_get']}" }
        return
      end
      target = URI(link[link_type])
    else
      target = uri + "/api/v1/timelines/#{path}"
    end
    get(target) do |body, meta|
      statuses = JSON.parse(body)
      statuses.reverse_each do |status|
        save_status(status)
      end
      if meta['link']
        link = parse_link(meta['link'])
      end
      link['last_get'] = target
      store[link_cache_key] = link
    end
  end

  def timelines_home(link_type = 'prev')
    timelines('home', link_type)
  end

  def timelines_public(link_type = 'prev')
    timelines('public', link_type)
  end

  def timelines_tag(tag, link_type = 'prev')
    encoded_tag = URI.encode_www_form_component(tag)
    timelines("tag/#{encoded_tag}", link_type)
  end

  def self.usage(opt, *error)
    puts opt
    puts <<-USAGE

For example:
  #{$0} http://localhost:3000
  #{$0} http://mastodon.dev home
  #{$0} http://mastodon.dev public
  #{$0} http://mastodon.dev tag:ruby
    USAGE
    abort(*error)
  end

  def self.parse_options(argv = ARGV)
    opt = OptionParser.new
    options = {
      link_type: 'prev',
      wait_ratelimit: true,
    }
    opt.banner += ' URL [home|public|tag:hashtag]'
    opt.on('--link-type=VALUE', %w[prev next],
           "timelines direction (default: #{options[:link_type]})") do |v|
      options[:link_type] = v
    end
    opt.on('--[no-]wait-ratelimit',
           "wait ratelimit (default: #{options[:wait_ratelimit]})") do |v|
      options[:wait_ratelimit] = v
    end
    begin
      opt.parse!(argv)
      options[:url] = argv.shift
      options[:timelines_type] = argv.shift
    rescue OptionParser::InvalidOption => e
      usage(opt, e.message)
    end
    unless options[:url]
      usage(opt)
    end
    [opt, options]
  end

  def self.run(argv = ARGV)
    opt, options = parse_options(argv)
    mlogger = new(options[:url])
    mlogger.logger.debug(PROG_NAME) { "options=#{options.inspect}" }
    mlogger.wait_ratelimit if options[:wait_ratelimit]
    case options[:timelines_type]
    when 'home', nil
      mlogger.timelines_home(options[:link_type])
    when 'public'
      mlogger.timelines_public(options[:link_type])
    when /\Atag:/
      mlogger.timelines_tag($', options[:link_type])
    else
      usage(opt)
    end
  end
end

if __FILE__ == $0
  MastodonLogger.run
end
