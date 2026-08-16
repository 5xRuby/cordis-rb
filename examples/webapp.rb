#!/usr/bin/env ruby
# frozen_string_literal: true

# A more realistic demo: a Sinatra app served by an embedded Falcon server,
# backed by SQLite — all wired together as cordis plugins.
#
# Dependencies are declared inline (bundler/inline), so the library's own
# Gemfile stays clean. Run with:
#
#   ruby examples/webapp.rb

Warning[:experimental] = false # silence Ruby 4's IO::Buffer notice from async's resolver

require 'bundler/inline'

gemfile(true) do
  source 'https://rubygems.org'
  gem 'async', '~> 2.35'
  gem 'falcon', '~> 0.57'
  gem 'sinatra', '~> 4.2', require: false
  gem 'sqlite3', '~> 2.9'
end

require 'async/http/internet'
require 'sinatra/base'
require_relative '../lib/cordis'

URL = 'http://localhost:9292'

def banner(text)
  puts
  puts "== #{text}"
end

def tick(count = 2)
  count.times { Async::Task.current.yield }
end

# One fresh connection per request: keep-alive pools would go stale across
# server bounces, and stale pools are not what this demo is about.
def get_users
  internet = Async::HTTP::Internet.new
  internet.get("#{URL}/users") { |response| "#{response.status} #{response.read}" }
rescue Errno::ECONNREFUSED
  'connection refused (no server)'
ensure
  internet&.close
end

ctx = Cordis::Context.new

# --- database plugin: provides :db, an in-memory SQLite seeded from config ---
database = lambda do |c, config|
  db = SQLite3::Database.new(':memory:')
  db.execute('CREATE TABLE users (name TEXT)')
  config[:seed].each { |name| db.execute('INSERT INTO users (name) VALUES (?)', [name]) }
  puts "   [db]  sqlite ready (seed: #{config[:seed].join(', ')})"
  c.effect do
    lambda {
      db.close
      puts '   [db]  sqlite closed (runs only after every dependent is gone)'
    }
  end
  c.provide(:db, db)
end

# --- web plugin: boots only while :db is provided; the Falcon server task is
#     an effect, so unloading the plugin shuts the server down ---
web = {
  name: 'web',
  inject: [:db],
  apply: lambda do |c, _config|
    app = Sinatra.new do
      set :environment, :production
      set :logging, false

      get '/users' do
        c.db.execute('SELECT name FROM users ORDER BY name').flatten.join(', ')
      end
    end

    endpoint = Async::HTTP::Endpoint.parse(URL)
    server = Falcon::Server.new(Falcon::Server.rack_middleware(app, cache: false), endpoint)
    task = server.run
    puts "   [web] falcon listening on #{URL}"
    lambda {
      task.stop
      puts '   [web] falcon stopped'
    }
  end
}

Sync do
  banner 'plugin(web) only: :db missing -> stays pending, no server'
  web_fiber = ctx.plugin(web)
  tick
  puts "   web state: #{web_fiber.state}"
  puts "   GET /users -> #{get_users}"

  banner 'plugin(database): provider active -> web boots automatically'
  db_fiber = ctx.plugin(database, { seed: %w[alice bob] })
  db_fiber.await
  tick
  puts "   GET /users -> #{get_users}"

  banner 'update(new seed): provider restarts -> site bounces onto the new db'
  db_fiber.update({ seed: %w[carol dave] })
  tick
  puts "   GET /users -> #{get_users}"

  banner 'dispose(database): dependents tear down first, then the provider (LIFO)'
  db_fiber.dispose
  puts "   web state: #{web_fiber.state}"
  puts "   GET /users -> #{get_users}"

  banner 'root dispose: the whole tree unwinds'
  ctx.fiber.dispose
  puts "   registry size: #{ctx.registry.size}"
end

puts
puts 'done.'
