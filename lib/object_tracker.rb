require 'benchmark'
require 'object_tracker/version'

module ObjectTracker
  def track(*args)
    args.each do |method_name|
      next if tracking?(method_name) || track_reserved_methods.include?(method_name)
      if respond_to?(method_name)
        track!(method_name => track_with_source(self, method_name))
      elsif respond_to?(:allocate)
        inst = allocate
        if inst.respond_to?(method_name)
          track!(method_name => track_with_source(inst, method_name))
        else
          fail UntrackableMethod, method_name
        end
      else
        fail UntrackableMethod, method_name
      end
    end
    nil
  end

  def tracking?(method_name)
    tracking.keys.include?(cleanse(method_name).to_sym)
  end

  def track_not(*args)
    args.each do |method_name|
      track_reserved_methods << method_name unless track_reserved_methods.include?(method_name)
    end
    nil
  end

  def track_all!(*args)
    track_not *args if args.any?
    track_methods_for(self)
    track_methods_for(allocate) if respond_to?(:allocate)
    track!
  end

  #
  # PRIVATE
  #

  def cleanse(str)
    str.to_s.sub(/^[#.]/, '')
  end

  def track!(method_names = nil)
    mod = Module.new
    Array(method_names || tracking).each do |method_name, source_def|
      mod.module_eval <<-RUBY, __FILE__, __LINE__
        def #{cleanse(method_name)}(*args)
          msg = %Q(   * called "#{method_name}" )
          msg << "with " << args.join(', ') << " " if args.any?
          msg << "[#{source_def}]"
          result = nil
          time = Benchmark.realtime { result = super }
          msg << " (" << time.to_s << ")"
          puts msg
          @__tracked_calls ||= Set.new
          @__tracked_calls << "#{method_name}"
          result
        rescue NoMethodError => e
          raise e if e.message !~ /no superclass/
        end
      RUBY
    end

    mod.module_eval <<-RUBY, __FILE__, __LINE__
      def self.prepended(base)
        base.extend(self)
      end
    RUBY

    # Handle both instance and class level extension
    if Class === self
      prepend(Inspector)
      prepend(mod)
    else
      extend(Inspector)
      extend(mod)
    end
  end

  def track_methods_for(obj)
    (obj.methods - track_reserved_methods).each do |method_name|
      track_with_source(obj, method_name)
    end
  end

  def track_with_source(obj, method_name)
    source = obj.method(method_name).source_location || ['RUBY CORE']
    prefix = obj.class == Class ? '.' : '#'
    tracking["#{prefix}#{method_name}".to_sym] = source.join(':').split('/').last(5).join('/')
  end

  def tracking
    @__tracking ||= {}
  end

  def track_reserved_methods
    @__reserved_methods ||= begin
      names = [:__send__, :object_id]
      names.concat [:default_scope, :base_class, :superclass, :<, :current_scope=] if defined?(Rails)
      names
    end
  end

  class UntrackableMethod < StandardError
    def initialize(method_name)
      super "Can't track :#{method_name} because it's not defined on this class or it's instance"
    end
  end

  module Inspector
    def inspect
      ivars = instance_variables - [:@__tracking, :@__tracked_calls, :@__reserved_methods]
      vars = ivars.map { |ivar| ivar.to_s + "=" + instance_variable_get(ivar).to_s }
      %Q(#<#{self.class.name}:#{object_id}(tracking)#{' ' if vars.any? }#{vars.join(', ')}>)
    end
  end
end