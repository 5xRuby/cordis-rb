#!/usr/bin/env ruby
# frozen_string_literal: true

# Demo:cordis-rb 的 plugin 生命週期與 reactive coeffect。
# 執行:bundle exec ruby examples/demo.rb

require 'async'
require_relative '../lib/cordis'

# 假資料庫,demo 用
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
  c.effect { -> { puts "   [db]  #{db.name} closed(所有依賴者都卸載後才執行)" } }
  c.provide(:db, db)
end

web = {
  name: 'web',
  inject: [:db],
  apply: lambda do |c, _config|
    puts "   [web] up(db=#{c.db.name})"
    c.on('request') { |path| puts "   [web] GET #{path} → #{c.db.query(path)}" }
    -> { puts "   [web] down(teardown 中仍可讀 db=#{c.db.name})" }
  end
}

Sync do
  banner 'plugin(web):依賴 :db,還沒有 provider → 停在 pending'
  web_fiber = ctx.plugin(web)
  tick
  puts "   web state: #{web_fiber.state}"

  banner 'plugin(database primary):provider 一 active,web 自動載入'
  db_fiber = ctx.plugin(database, { name: 'primary' })
  db_fiber.await
  tick
  puts "   web state: #{web_fiber.state}"
  ctx.emit('request', '/users')

  banner 'update(replica):provider 重啟 → web 先卸載、再用新 db 重載'
  db_fiber.update({ name: 'replica' })
  tick
  ctx.emit('request', '/orders')

  banner 'dispose(database):依賴者先 teardown,再輪到 provider 自己(LIFO)'
  db_fiber.dispose
  puts "   web state: #{web_fiber.state}(回到 pending,等下一個 provider)"

  banner 'root dispose:整棵樹 LIFO 撤除'
  ctx.fiber.dispose
  puts "   registry size: #{ctx.registry.size}"
end

puts
puts 'done.'
