require 'fileutils'
namespace :elvuel do

  # Fetch all has*** :as => item polymorphic associations
  def store_polymorphic_as_associations(models)
    reflects = []
    models.each do |model|
      model.reflections.each do |key, association|
        reflects << association if association.send(:options).has_key?(:as) #only polymorphic
      end
    end

    @polymorphic_as_reflections = reflects
  end

  # Model belongs_to :item, :polymorphic => true, get all item's class
  def get_polymorphic_as_associations_classes(model, reflection)
    classes = []
    @polymorphic_as_reflections.each do |poly_as_reflection|
      if poly_as_reflection.send(:options)[:as] == reflection.send(:name)
        if poly_as_reflection.active_record.send(:compute_type, poly_as_reflection.send(:class_name)).to_s == model.to_s
          classes << poly_as_reflection.active_record.to_s.constantize
        end
      end
    end
    classes
  end

  # Simple quoting for the default column value
  def quote(value)
    case value
      when NilClass then
        "NULL"
      when TrueClass then
        "TRUE"
      when FalseClass then
        "FALSE"
      when Float, Fixnum, Bignum then
        value.to_s
      # BigDecimals need to be output in a non-normalized form and quoted.
      when BigDecimal then
        value.to_s('F')
      else
        value.inspect
    end
  end

  # Use the column information in an ActiveRecord class
  # to create a comment block containing a line for
  # each column. The line contains the column name,
  # the type (and length), and any optional attributes
  def get_schema_info(klass, options)
    info = []
    klass.columns.each do |col|
      attrs = []
      attrs << "default(#{quote(col.default)})" unless col.default.nil?
      attrs << "not null" unless col.null
      attrs << "primary key" if col.name == klass.primary_key

      col_type = col.type.to_s
      if col_type == "decimal"
        col_type << "(#{col.precision}, #{col.scale})"
      else
        col_type << "(#{col.limit})" if col.limit
      end

      # Check out if we got a geometric column
      # and print the type and SRID
      if col.respond_to?(:geometry_type)
        attrs << "#{col.geometry_type}, #{col.srid}"
      end

      # Check if the column has indices and print "indexed" if true
      # If the indice include another colum, print it too.
      if options[:simple_indexes] # Check out if this column is indexed
        indices = klass.connection.indexes(klass.table_name)
        if indices = indices.select { |ind| ind.columns.include? col.name }
          indices.each do |ind|
            ind = ind.columns.reject! { |i| i == col.name }
            attrs << (ind.length == 0 ? "indexed" : "indexed => [#{ind.join(", ")}]")
          end
        end
      end
      info << { :name => col.name, :type => col_type, :attrs => attrs.join(", "), :human_name => klass.respond_to?(:human_attribute_name) ? klass.human_attribute_name(col.name) : col.name }
    end
    info
  end

  # Get table indexes info
  def get_index_info(klass)
    index_info = []
    indexes = klass.connection.indexes(klass.table_name)
    indexes.each do |index|
      index_info << { :name => index.name, :columns => index.columns.join(", "), :unique => (index.unique ? "UNIQUE" : "NO") }
    end
    index_info
  end

  # Get association info
  def get_association_info(klass)
    reflections = klass.reflections
    associations = []
    unless reflections.empty?
      reflections.each do |key, association|
        begin
          info = {}

          info[:name]= key.to_s
          info[:type]= association.class.to_s.gsub(/ActiveRecord|Reflection|::/, "")
          info[:macro]= association.send(:macro).to_s

          # ActiveRecord::Reflection::ThroughReflection[::AssociationReflection|::AggregateReflection]
          association_classes = []

          case info[:macro].to_sym
            when :belongs_to
              if association.send(:options).has_key?(:polymorphic)
                association_classes = get_polymorphic_as_associations_classes(klass, association)
              else
                if association.send(:options).has_key?(:class_name)
                  association_classes << association.send(:class_name).constantize
                else
                  association_classes << association.active_record.send(:compute_type, association.send(:class_name))
                end
              end
            when :has_and_belongs_to_many
              if association.send(:options).has_key?(:class_name)
                association_classes << association.send(:class_name).constantize
              else
                association_classes << association.active_record.send(:compute_type, association.send(:class_name))
              end

            when :has_many, :has_one
              if association.send(:options).has_key?(:class_name)
                association_classes << association.send(:class_name).constantize
              else
                association_classes << association.send(:name).to_s.singularize.capitalize.constantize
              end
            else
              association_classes = []
          end

          info[:association_classes]= association_classes.map(&:to_s)
          info[:foreign_key]= association.send(:association_foreign_key).to_s
          info[:primary_key]= begin
            association.send(:association_primary_key).to_s
          rescue
            "pending"
          end
          info[:options]= association.send(:options).inspect if association.respond_to?(:options)

          associations << info
        rescue Exception => e
          @exception_associations[klass.to_s] ||= []
          @exception_associations[klass.to_s] << "#{association.send(:macro).to_s} :#{key}"
        end
      end
    end
    associations
  end


  # Get all ActiveRecord named_scopes
  def get_named_scope_info(klass)
    klass.respond_to?(:scopes) ? klass.scopes.keys.map(&:to_s) : []
  end

  # Get model singleton methods
  def get_singleton_methods_info(klass)
    klass.singleton_methods(false).map(&:to_s)
  end

  # check ruby version from github.com/jgoizueta/modalsupport
  def ruby_version?(cmp, v)
    rv = Gem::Version.create(RUBY_VERSION.dup)
    v  = Gem::Version.create(v)
    if cmp.to_sym==:'~>'
      rv = rv.release
      rv >= v && rv < v.bump
    else
      rv.send(cmp, v)
    end
  end

  # check ruby platform from github.com/jgoizueta/modalsupport
  def ruby_platform_is?(platform)
    ruby_platform = ruby_version?(:<, '1.9.0') ? PLATFORM : RUBY_PLATFORM
    case platform
      when :unix
        ruby_platform =~ /linux|darwin|freebsd|netbsd|solaris|aix|hpux|cygwin/
      when :linux
        ruby_platform =~ /linux/
      when :osx, :darwin
        ruby_platform =~ /darwin/
      when :bsd
        ruby_platform =~ /freebsd|netbsd/
      when :cygwin
        ruby_platform =~ /cygwin/
      when :windows
        ruby_platform =~ /mswin32|mingw32/
      when :mswin32
        ruby_platform =~ /mswin32/
      when :mingw32
        ruby_platform =~ /mingw32/
      when :java
        ruby_platform =~ /java/
      else
        raise RuntimeError, "Invalid platform specifier"
    end ? true : false
  end

  desc 'genenrate config file'
  task :config do
    config = {}
    config['app'] = ENV['APP'] || "app"
    config["template_folder"] = "doc/templates"
    
    FileUtils.mkdir_p config['template_folder']

    config['output_folder'] = "doc/model_db"
    config['index'] = { 'template' => "#{config['template_folder']}/index_template.erb", 'output' => config['output_folder'] }
    config['model'] = { 'template' => "#{config['template_folder']}/model_template.erb", 'output' => config['output_folder'] }
    config['models_yml']  = "#{config['template_folder']}/models.yml"
    config['folders'] = [ "app/models" ]
    config['config'] = ENV['CONFIG'] || "config/db_doc_gen.yml"

    File.open(config['config'],'w') do |f|
      if config.respond_to?(:ya2yaml)
        f.write config.ya2yaml(:syck_compatible => true)
      else
        f.write config.to_yaml
      end
    end
    puts "Please setup your config file '#{config['config']}'"
  end

  desc 'preset'
  task :preset do
    @config ||= YAML.load_file(ENV['CONFIG'] || "config/db_doc_gen.yml")
    @exception_associations ||= {}
  end

  desc 'generate doc files'
  task :gen_dbdoc_files => :preset do
    FileUtils.mkdir_p @config['output_folder']
    FileUtils.cp_r @config["template_folder"] + "/css", @config['output_folder']

    Rake::Task["elvuel:load_model_info"].invoke if ENV['FORCE_RELOAD']
    
    # gen index file
    doc = YAML.load_file(@config["models_yml"])

    @app_name = @config["app"]
    # except Symbol :exception_associations
    models = doc.keys.reject { |key| key.is_a? Symbol }
    @alphabetic_indexes = models.inject({}) do |hash, value|
      alpha_key = value[0].chr.upcase
      hash[alpha_key] ||= []
      hash[alpha_key] << doc[value][:name]
      hash
    end
    File.open("#{@config["index"]["output"]}/index.html", "w") { |f| f.write ERB.new(File.read("#{@config["index"]["template"]}")).result }
    models.each do |model|
      @model = model
      @inherits = doc[model][:super_classes]
      @defined_in = doc[model][:defined_in].split(",")
      @database = doc[model][:database]
      @table_name = doc[model][:table_name]
      @human_name = doc[model][:human_name]
      @schema = doc[model][:table_schema]
      @db_indexes = doc[model][:table_indexes]
      @associations = doc[model][:associations]
      @named_scopes = doc[model][:named_scopes]
      @singleton_methods = doc[model][:singleton_methods]

      File.open("#{@config["model"]["output"]}/#{model.underscore.gsub("/", "_")}.html", "w") { |f| f.write ERB.new(File.read("#{@config["model"]["template"]}")).result }
    end

    unless doc[:exception_associations].empty?
      content = []
      doc[:exception_associations].each do |key, value|
        content << "#{key}: #{value.join(", ")}"
      end
      File.open("#{@config["model"]["output"]}/exception_associations.log", "w") do |f|
        f.write content.join("\n")
      end
    end
    puts "Docs generated."
  end

  desc 'load models info'
  task :load_model_info => [:preset, :environment] do

    FileUtils.touch @config['models_yml']
    FileUtils.rm @config['models_yml']

    # set i18n locale
    I18n.locale = :zh if defined? I18n

    model_folders = @config["folders"]

    # require all files under 'models folder'
    model_folders.each { |folder| Dir.glob(File.join(folder, "**", "*.rb")).each{ |file| require File.join(Rails.root, file) } }

    # get all ActiveRecord::Base subclasses
    models = []
    ObjectSpace.each_object(Class) do |klass|
      if klass.ancestors.include?(ActiveRecord::Base)
        unless klass.abstract_class?
          models << klass if klass != ActiveRecord::Base
        end
      end
    end

    # @polymorphic_as_reflections init
    store_polymorphic_as_associations(models)

    # get all files which contain class define
    # TODO diff platform model class define fetch!
    if ruby_platform_is? :linux
      find_cmd = "find ./ \\( -path './vendor/rails*' -o -path './test*' -o -path './db/migrate*' -o -path './rspec*' \\) -a -prune -o -type f -name \"*.rb\" | xargs grep -n -E \"[ \\t\\f\\v]*class[ \\f\\n\\r\\t\\v]+[A-Z]+\\S*[ \\f\\n\\r\\t\\v]+<\""
    elsif ruby_platform_is? :darwins
      find_cmd = "find ./ -type f -name \"*.rb\" | xargs grep -n -E \"[ \\t\\f\\v]*class[ \\f\\n\\r\\t\\v]+[A-Z].*[ \\f\\n\\r\\t\\v]+<\""
    else
      # ...
      find_cmd = "echo ''"
    end

    all_class_defines = `#{find_cmd}`.split("\n")

    doc = {}

    models.each_with_index do |model, index|
      key = model.to_s

      puts "#{key}-#{index}"
      doc[key] = {}
      doc[key][:name] = key

      table_exist = begin
        model.send(:columns)
        true
      rescue
        false
      end

      #storaged_db = model.connection.current_database
      db_config = model.connection.instance_variable_get(:@config)
      if db_config
        storaged_db = db_config[:database].to_s
      else
        storaged_db = ''
      end

      storaged_db.gsub!(/#{Rails.root}/, '')

      if table_exist
        if model.columns.empty? # tableless
          doc[key][:database]      = "Tableless(none)"
          doc[key][:table_name]    = "Tableless(none)"
          doc[key][:table_schema]  = "Tableless(none)"
          doc[key][:table_indexes] = "Tableless(none)"
        else
          p model.connection.methods.grep(/data/).sort
          doc[key][:database]      = storaged_db
          doc[key][:table_name]    = model.table_name
          doc[key][:table_schema]  = get_schema_info(model, :simple_indexes => true)
          doc[key][:table_indexes] = get_index_info(model)
        end
      else
        doc[key][:database]      = storaged_db
        doc[key][:table_name]    = model.table_name
        doc[key][:table_schema]  = [{ :name => "table #{storaged_db}.#{model.table_name} doesn't exist", :type => "NULL", :attrs => "NULL", :human_name => "NULL"  }]
        doc[key][:table_indexes] = [{ :name => "table #{storaged_db}.#{model.table_name} doesn't exist", :columns => "NULL", :unique => "NULL" }]
      end

      # I18n human name
      doc[key][:human_name] = model.respond_to?(:human_name)? model.human_name : key
      # all associations
      doc[key][:associations] = get_association_info(model)
      # all named scopes
      doc[key][:named_scopes] = get_named_scope_info(model)
      doc[key][:singleton_methods] = get_singleton_methods_info(model)

      # super class
      super_classes = []
      sp_klass = model.superclass
      begin
        super_classes << sp_klass.to_s if sp_klass != Object
        sp_klass = sp_klass.superclass
        sp_klass = nil if sp_klass and (sp_klass == ActiveRecord::Base)
      end while sp_klass

      doc[key][:super_classes] = super_classes

      # declaration file
      reg_last = Regexp.new("class\\s+#{key.split("::").last}\\s+<")
      reg_full = Regexp.new("class\\s+#{key}\\s+<")
      paths = all_class_defines.grep(reg_last).concat(all_class_defines.grep(reg_full)).uniq

      doc[key][:defined_in] = paths.collect{ |line| "#{line.split(":")[0]} - line:(#{line.split(":")[1]})" }

    end

    doc[:exception_associations] = @exception_associations

    File.open(@config["models_yml"],'w') do |f|
      if doc.respond_to?(:ya2yaml)
        f.write doc.ya2yaml(:syck_compatible => true)
      else
        f.write doc.to_yaml
      end
    end

    puts "Model info loaded."
  end

end
