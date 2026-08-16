#!/usr/bin/env ruby
# frozen_string_literal: true

# Demo: cordis-rb's plugin lifecycle and reactive coeffects.
# Run with: bundle exec ruby examples/demo.rb

require 'async'
require_relative '../lib/cordis'

# Fake database for the demo
class FakeDB
  attr_reader :name

  def initialize(name)
    @name = name
  end

  def query(sql) = "#{name}:#{sql}"
end

def tick(count = 2)
  count.times { Async::Task.current.yield }
end

def banner(text)
  puts
  puts "== #{text}"
end

ctx = Cordis::Context.new

database = lambda do |c, config|
  db = FakeDB.new(config[:name])
  puts "   [db]  #{db.name} connected"
  c.effect { -> { puts "   [db]  #{db.name} closed (runs only after every dependent is gone)" } }
  c.provide(:db, db)
end

web = {
  name: 'web',
  inject: [:db],
  apply: lambda do |c, _config|
    puts "   [web] up (db=#{c.db.name})"
    c.on('request') { |path| puts "   [web] GET #{path} -> #{c.db.query(path)}" }
    -> { puts "   [web] down (db=#{c.db.name} still readable during teardown)" }
  end
}

Sync do
  banner 'plugin(web): depends on :db, no provider yet -> stays pending'
  web_fiber = ctx.plugin(web)
  tick
  puts "   web state: #{web_fiber.state}"

  banner 'plugin(database primary): once the provider is active, web loads automatically'
  db_fiber = ctx.plugin(database, { name: 'primary' })
  db_fiber.await
  tick
  puts "   web state: #{web_fiber.state}"
  ctx.emit('request', '/users')

  banner 'update(replica): provider restarts -> web unloads first, then reloads with the new db'
  db_fiber.update({ name: 'replica' })
  tick
  ctx.emit('request', '/orders')

  banner 'dispose(database): dependents tear down first, then the provider itself (LIFO)'
  db_fiber.dispose
  puts "   web state: #{web_fiber.state} (back to pending, waiting for the next provider)"

  banner 'root dispose: the whole tree unwinds in LIFO order'
  ctx.fiber.dispose
  puts "   registry size: #{ctx.registry.size}"
end

puts
puts 'done.'
