# frozen_string_literal: true

module Cordis
  # Class-style plugin that provides itself as a service (upstream Service base class).
  # Declare the name with `provide :foo` and dependencies with `inject`; the instance
  # becomes the service value, and #init (if defined) runs as the plugin load body.
  #
  #   class AuditLog < Cordis::Service
  #     provide :audit
  #     inject :db
  #     def init = ctx.on('request') { ... }
  #   end
  #   ctx.plugin(AuditLog)
  class Service
    class << self
      # DSL setter and registry-facing getter in one (upstream `static provide`).
      def provide(name = nil)
        @service_name = name.to_sym if name
        @service_name
      end

      # `inject :foo, :bar` or `inject foo: { config }` (upstream `static inject`);
      # called with no arguments it returns the accumulated map for the registry.
      def inject(*names, **configs)
        @inject ||= {}
        names.each { |dep| @inject[dep.to_sym] = true }
        configs.each { |dep, cfg| @inject[dep.to_sym] = cfg }
        @inject
      end
    end

    attr_reader :ctx, :name, :config

    def initialize(ctx, config = nil)
      name = self.class.provide
      raise ArgumentError, "#{self.class} must declare `provide :name`" unless name

      @ctx = ctx
      @config = config
      @name = name
      ctx.provide(name, self)
    end

    # Load-time hook: runs while the fiber is still loading, so blocking here keeps
    # the service invisible to dependents (upstream's "pending inject" via Service.init).
    # A callable return value is collected as a disposer.
    def init; end
  end
end
