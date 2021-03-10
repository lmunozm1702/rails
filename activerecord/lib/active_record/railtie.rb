# frozen_string_literal: true

require "active_record"
require "rails"
require "active_support/core_ext/object/try"
require "active_model/railtie"

# For now, action_controller must always be present with
# Rails, so let's make sure that it gets required before
# here. This is needed for correctly setting up the middleware.
# In the future, this might become an optional require.
require "action_controller/railtie"

module ActiveRecord
  # = Active Record Railtie
  class Railtie < Rails::Railtie # :nodoc:
    config.active_record = ActiveSupport::OrderedOptions.new
    config.active_record.encryption = ActiveSupport::OrderedOptions.new

    config.app_generators.orm :active_record, migration: true,
                                              timestamps: true

    config.action_dispatch.rescue_responses.merge!(
      "ActiveRecord::RecordNotFound"   => :not_found,
      "ActiveRecord::StaleObjectError" => :conflict,
      "ActiveRecord::RecordInvalid"    => :unprocessable_entity,
      "ActiveRecord::RecordNotSaved"   => :unprocessable_entity
    )

    config.active_record.use_schema_cache_dump = true
    config.active_record.check_schema_cache_dump_version = true
    config.active_record.maintain_test_schema = true
    config.active_record.has_many_inversing = false

    config.active_record.queues = ActiveSupport::InheritableOptions.new

    config.eager_load_namespaces << ActiveRecord

    rake_tasks do
      namespace :db do
        task :load_config do
          if defined?(ENGINE_ROOT) && engine = Rails::Engine.find(ENGINE_ROOT)
            if engine.paths["db/migrate"].existent
              ActiveRecord::Tasks::DatabaseTasks.migrations_paths += engine.paths["db/migrate"].to_a
            end
          end
        end
      end

      load "active_record/railties/databases.rake"
    end

    # When loading console, force ActiveRecord::Base to be loaded
    # to avoid cross references when loading a constant for the
    # first time. Also, make it output to STDERR.
    console do |app|
      require "active_record/railties/console_sandbox" if app.sandbox?
      require "active_record/base"
      unless ActiveSupport::Logger.logger_outputs_to?(Rails.logger, STDERR, STDOUT)
        console = ActiveSupport::Logger.new(STDERR)
        console.level = Rails.logger.level
        Rails.logger.extend ActiveSupport::Logger.broadcast console
      end
      ActiveRecord::Base.verbose_query_logs = false
    end

    runner do
      require "active_record/base"
    end

    initializer "active_record.initialize_timezone" do
      ActiveSupport.on_load(:active_record) do
        self.time_zone_aware_attributes = true
        self.default_timezone = :utc
      end
    end

    initializer "active_record.logger" do
      ActiveSupport.on_load(:active_record) { self.logger ||= ::Rails.logger }
    end

    initializer "active_record.backtrace_cleaner" do
      ActiveSupport.on_load(:active_record) { LogSubscriber.backtrace_cleaner = ::Rails.backtrace_cleaner }
    end

    initializer "active_record.migration_error" do |app|
      if config.active_record.delete(:migration_error) == :page_load
        config.app_middleware.insert_after ::ActionDispatch::Callbacks,
          ActiveRecord::Migration::CheckPending,
          file_watcher: app.config.file_watcher
      end
    end

    initializer "active_record.database_selector" do
      if options = config.active_record.delete(:database_selector)
        resolver = config.active_record.delete(:database_resolver)
        operations = config.active_record.delete(:database_resolver_context)
        config.app_middleware.use ActiveRecord::Middleware::DatabaseSelector, resolver, operations, options
      end
    end

    initializer "Check for cache versioning support" do
      config.after_initialize do |app|
        ActiveSupport.on_load(:active_record) do
          if app.config.active_record.cache_versioning && Rails.cache
            unless Rails.cache.class.try(:supports_cache_versioning?)
              raise <<-end_error

You're using a cache store that doesn't support native cache versioning.
Your best option is to upgrade to a newer version of #{Rails.cache.class}
that supports cache versioning (#{Rails.cache.class}.supports_cache_versioning? #=> true).

Next best, switch to a different cache store that does support cache versioning:
https://guides.rubyonrails.org/caching_with_rails.html#cache-stores.

To keep using the current cache store, you can turn off cache versioning entirely:

    config.active_record.cache_versioning = false

              end_error
            end
          end
        end
      end
    end

    initializer "active_record.check_schema_cache_dump" do
      check_schema_cache_dump_version = config.active_record.delete(:check_schema_cache_dump_version)

      if config.active_record.delete(:use_schema_cache_dump)
        config.after_initialize do |app|
          ActiveSupport.on_load(:active_record) do
            db_config = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).first

            filename = ActiveRecord::Tasks::DatabaseTasks.cache_dump_filename(
              db_config.name,
              schema_cache_path: db_config&.schema_cache_path
            )

            cache = ActiveRecord::ConnectionAdapters::SchemaCache.load_from(filename)
            next if cache.nil?

            if check_schema_cache_dump_version
              current_version = begin
                ActiveRecord::Migrator.current_version
              rescue ActiveRecordError => error
                warn "Failed to validate the schema cache because of #{error.class}: #{error.message}"
                nil
              end
              next if current_version.nil?

              if cache.version != current_version
                warn "Ignoring #{filename} because it has expired. The current schema version is #{current_version}, but the one in the cache is #{cache.version}."
                next
              end
            end

            connection_pool.set_schema_cache(cache)
          end
        end
      end
    end

    initializer "active_record.define_attribute_methods" do |app|
      config.after_initialize do
        ActiveSupport.on_load(:active_record) do
          if app.config.eager_load
            begin
              descendants.each do |model|
                # If the schema cache was loaded from a dump, we can use it without connecting
                schema_cache = model.connection_pool.schema_cache

                # If there's no connection yet, we avoid connecting.
                schema_cache ||= model.connected? && model.connection.schema_cache

                # If the schema cache doesn't have the columns
                # hash for the model cached, `define_attribute_methods` would trigger a query.
                if schema_cache && schema_cache.columns_hash?(model.table_name)
                  model.define_attribute_methods
                end
              end
            rescue ActiveRecordError => error
              # Regardless of whether there was already a connection or not, we rescue any database
              # error because it is critical that the application can boot even if the database
              # is unhealthy.
              warn "Failed to define attribute methods because of #{error.class}: #{error.message}"
            end
          end
        end
      end
    end

    initializer "active_record.warn_on_records_fetched_greater_than" do
      if config.active_record.warn_on_records_fetched_greater_than
        ActiveSupport.on_load(:active_record) do
          require "active_record/relation/record_fetch_warning"
        end
      end
    end

    initializer "active_record.set_configs" do |app|
      ActiveSupport.on_load(:active_record) do
        configs = app.config.active_record

        configs.each do |k, v|
          send "#{k}=", v if k != :encryption
        end
      end
    end

    # This sets the database configuration from Configuration#database_configuration
    # and then establishes the connection.
    initializer "active_record.initialize_database" do
      ActiveSupport.on_load(:active_record) do
        if ActiveRecord::Base.legacy_connection_handling
          self.connection_handlers = { writing_role => ActiveRecord::Base.default_connection_handler }
        end
        self.configurations = Rails.application.config.database_configuration
        establish_connection
      end
    end

    # Expose database runtime to controller for logging.
    initializer "active_record.log_runtime" do
      require "active_record/railties/controller_runtime"
      ActiveSupport.on_load(:action_controller) do
        include ActiveRecord::Railties::ControllerRuntime
      end
    end

    initializer "active_record.set_reloader_hooks" do
      ActiveSupport.on_load(:active_record) do
        ActiveSupport::Reloader.before_class_unload do
          if ActiveRecord::Base.connected?
            ActiveRecord::Base.clear_cache!
            ActiveRecord::Base.clear_reloadable_connections!
          end
        end
      end
    end

    initializer "active_record.set_executor_hooks" do
      ActiveRecord::QueryCache.install_executor_hooks
      ActiveRecord::AsynchronousQueriesTracker.install_executor_hooks
    end

    initializer "active_record.add_watchable_files" do |app|
      path = app.paths["db"].first
      config.watchable_files.concat ["#{path}/schema.rb", "#{path}/structure.sql"]
    end

    initializer "active_record.clear_active_connections" do
      config.after_initialize do
        ActiveSupport.on_load(:active_record) do
          # Ideally the application doesn't connect to the database during boot,
          # but sometimes it does. In case it did, we want to empty out the
          # connection pools so that a non-database-using process (e.g. a master
          # process in a forking server model) doesn't retain a needless
          # connection. If it was needed, the incremental cost of reestablishing
          # this connection is trivial: the rest of the pool would need to be
          # populated anyway.

          clear_active_connections!
          flush_idle_connections!
        end
      end
    end

    initializer "active_record.set_filter_attributes" do
      ActiveSupport.on_load(:active_record) do
        self.filter_attributes += Rails.application.config.filter_parameters
      end
    end

    initializer "active_record.set_signed_id_verifier_secret" do
      ActiveSupport.on_load(:active_record) do
        self.signed_id_verifier_secret ||= -> { Rails.application.key_generator.generate_key("active_record/signed_id") }
      end
    end

    initializer "active_record_encryption.configuration" do |app|
      config.before_initialize do
        ActiveRecord::Encryption.configure \
           master_key: app.credentials.dig(:active_record_encryption, :master_key) || ENV["ACTIVE_RECORD_ENCRYPTION_MASTER_KEY"],
           deterministic_key: app.credentials.dig(:active_record_encryption, :deterministic_key) || ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"],
           key_derivation_salt: app.credentials.dig(:active_record_encryption, :key_derivation_salt) || ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"],
           **config.active_record.encryption

        # Encrypt active record fixtures
        if ActiveRecord::Encryption.config.encrypt_fixtures
          class ActiveRecord::Fixture
            prepend ActiveRecord::Encryption::EncryptedFixtures
          end
        end

        # Support extended queries for deterministic attributes
        if ActiveRecord::Encryption.extend_queries_to_support_previous_deterministic_encryption_schemes
          ActiveRecord::Encryption::ExtendedDeterministicQueries.install_support
        end

        # Filtered params
        ActiveSupport.on_load(:action_controller) do
          if ActiveRecord::Encryption.config.add_to_filter_parameters
            ActiveRecord::Encryption.install_auto_filtered_parameters(app)
          end
        end
      end
    end
  end
end
