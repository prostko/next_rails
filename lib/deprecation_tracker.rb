require "rainbow"
require "json"

# A shitlist for deprecation warnings during test runs. It has two modes: "save" and "compare"
#
# DEPRECATION_TRACKER=save
# Record deprecation warnings, grouped by spec file. After the test run, save to a file.
#
# DEPRECATION_TRACKER=compare
# Tracks deprecation warnings, grouped by spec file. After the test run, compare against shitlist of expected
# deprecation warnings. If anything is added or removed, raise an error with a diff of the changes.
#
class DeprecationTracker
  UnexpectedDeprecations = Class.new(StandardError)

  module KernelWarnTracker
    def self.callbacks
      @callbacks ||= []
    end

    def warn(*messages, **kwargs)      
      KernelWarnTracker.callbacks.each do |callback|
        messages.each { |message| callback.(message) }
      end

      if Gem::Version.new(RUBY_VERSION) < Gem::Version.new("2.5.0")
        super(*messages)
      elsif Gem::Version.new(RUBY_VERSION) < Gem::Version.new("3.0")
        super(*messages, uplevel: nil)
      else
        super
      end
    end
  end

  module MinitestExtension
    def self.new(deprecation_tracker)
      @@deprecation_tracker = deprecation_tracker

      Module.new do
        def before_setup
          test_file_name = method(name).source_location.first.to_s
          @@deprecation_tracker.bucket = test_file_name.gsub(Rails.root.to_s, ".")
          super
        end
      
        def after_teardown
          super
          @@deprecation_tracker.bucket = nil
        end
      end
    end
  end

  # There are two forms of the `warn` method: one for class Kernel and one for instances of Kernel (i.e., every Object)
  if Object.respond_to?(:prepend)
    Object.prepend(KernelWarnTracker)
  else
    Object.extend(KernelWarnTracker)
  end

  # Ruby 2.2 and lower doesn't appear to allow overriding of Kernel.warn using `singleton_class.prepend`.
  if Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("2.3.0")
    Kernel.singleton_class.prepend(KernelWarnTracker)
  else
    def Kernel.warn(*args, &block)
      Object.warn(*args, &block)
    end
  end

  def self.init_tracker(opts = {})
    shitlist_path = opts[:shitlist_path]
    mode = opts[:mode]
    transform_message = opts[:transform_message]
    deprecation_tracker = DeprecationTracker.new(shitlist_path, transform_message, mode)
    # Since Rails 7.1 the preferred way to track deprecations is to use the deprecation trackers via
    # `Rails.application.deprecators`.
    # We fallback to tracking deprecations via the ActiveSupport singleton object if Rails.application.deprecators is
    # not defined for older Rails versions.
    if defined?(Rails) && defined?(Rails.application) && defined?(Rails.application.deprecators)
      Rails.application.deprecators.each do |deprecator|
        deprecator.behavior << -> (message, _callstack = nil, _deprecation_horizon = nil, _gem_name = nil) {
          deprecation_tracker.add(message)
        }
      end
    elsif defined?(ActiveSupport)
      ActiveSupport::Deprecation.behavior << -> (message, _callstack = nil, _deprecation_horizon = nil, _gem_name = nil) {
        deprecation_tracker.add(message)
      }
    end
    KernelWarnTracker.callbacks << -> (message) { deprecation_tracker.add(message) }

    deprecation_tracker
  end

  def self.track_rspec(rspec_config, opts = {})
    deprecation_tracker = init_tracker(opts)

    rspec_config.around do |example|
      deprecation_tracker.bucket = example.metadata.fetch(:rerun_file_path)

      begin
        example.run
      ensure
        deprecation_tracker.bucket = nil
      end
    end

    rspec_config.after(:suite) do
      deprecation_tracker.after_run
    end
  end

  def self.track_minitest(opts = {})
    tracker = init_tracker(opts)

    Minitest.after_run do
      tracker.after_run
    end

    ActiveSupport::TestCase.include(MinitestExtension.new(tracker))
  end

  attr_reader :deprecation_messages, :shitlist_path, :transform_message, :bucket, :mode

  def initialize(shitlist_path, transform_message = nil, mode = :save)
    @shitlist_path = shitlist_path
    @transform_message = transform_message || -> (message) { message }
    @deprecation_messages = {}
    @mode = mode.to_sym
  end

  def add(message)
    return if bucket.nil?

    @deprecation_messages[bucket] << transform_message.(message)
  end

  def bucket=(value)
    @bucket = value
    @deprecation_messages[value] ||= [] unless value.nil?
  end

  def after_run
    if mode == :save
      save
    elsif mode == :compare
      compare
    end
  end

  def compare
    shitlist = read_shitlist

    changed_buckets = []
    normalized_deprecation_messages.each do |bucket, messages|
      if shitlist[bucket] != messages
        changed_buckets << bucket
      end
    end

    if changed_buckets.length > 0
      message = <<-MESSAGE
        ⚠️  Deprecation warnings have changed!

        Code called by the following spec files is now generating different deprecation warnings:

        #{changed_buckets.join("\n")}

        To check your failures locally, you can run:

        DEPRECATION_TRACKER=compare bundle exec rspec #{changed_buckets.join(" ")}

        Here is a diff between what is expected and what was generated by this process:

        #{diff}

        See \e[4;37mdev-docs/testing/deprecation_tracker.md\e[0;31m for more information.
      MESSAGE

      raise UnexpectedDeprecations, Rainbow(message).red
    end
  end

  def diff
    new_shitlist = create_temp_shitlist
    `git diff --no-index #{shitlist_path} #{new_shitlist.path}`
  ensure
    new_shitlist.delete
  end

  def save
    new_shitlist = create_temp_shitlist
    create_if_shitlist_path_does_not_exist
    FileUtils.cp(new_shitlist.path, shitlist_path)
  ensure
    new_shitlist.delete if new_shitlist
  end

  def create_if_shitlist_path_does_not_exist
    dirname = File.dirname(shitlist_path)
    unless File.directory?(dirname)
      FileUtils.mkdir_p(dirname)
    end
  end

  def create_temp_shitlist
    temp_file = Tempfile.new("temp-deprecation-tracker-shitlist")
    temp_file.write(JSON.pretty_generate(normalized_deprecation_messages))
    temp_file.flush

    temp_file
  end

  # Normalize deprecation messages to reduce noise from file output and test files to be tracked with separate test runs
  def normalized_deprecation_messages
    normalized = read_shitlist.merge(deprecation_messages).each_with_object({}) do |(bucket, messages), hash|
      hash[bucket] = messages.sort
    end

    # not using `to_h` here to support older ruby versions
    {}.tap do |h|
      normalized.reject {|_key, value| value.empty? }.sort_by {|key, _value| key }.each do |k ,v|
        h[k] = v
      end
    end
  end

  def read_shitlist
    return {} unless File.exist?(shitlist_path)
    JSON.parse(File.read(shitlist_path))
  rescue JSON::ParserError => e
    raise "#{shitlist_path} is not valid JSON: #{e.message}"
  end
end
