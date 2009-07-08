def obtain_class
  class_name = ENV['CLASS'] || ENV['class']
  raise "Must specify CLASS" unless class_name
  @klass = Object.const_get(class_name)
end

def obtain_attachments
  name = ENV['ATTACHMENT'] || ENV['attachment']
  raise "Class #{@klass.name} has no attachments specified" unless @klass.respond_to?(:attachment_definitions)
  if !name.blank? && @klass.attachment_definitions.keys.include?(name)
    [ name ]
  else
    @klass.attachment_definitions.keys
  end
end

def set_logger
  #configure ActiveRecord to log to Stdout
  if (log = (ENV['LOG']||ENV['log'])) && log.to_s.downcase != 'false'
    ActiveRecord::Base.logger = Logger.new(STDOUT)
    ActiveRecord::Base.logger.level = begin
      log =~ /^\d*$/ ? log.to_i : Logger.const_get(log.upcase)
    rescue
      Logger::INFO
    end
    puts "ActiveRecord to STDOUT level #{ActiveRecord::Base.logger.level}"
    ActiveRecord::Base.connection.instance_variable_set('@logger', ActiveRecord::Base.logger)
    Paperclip.options[:log] = true
  end
end

def obtain_settings
  @verbose = (ENV['VERBOSE']||ENV['verbose']).to_s.downcase == 'true'
  @skip_errors = (ENV['skip_errors']||ENV['SKIP_ERRORS']).to_s.downcase == 'true'
  print_message("Verbose: #{@verbose}, Skipping Errors #{@skipping_errors}", true)
  set_logger
end

# Add the error to the list if we are tracking errors
# Print the error out now when in verbose mode
def add_error(id, name, error_message, additional_message)
  if @errors
    @errors[name]||= []
    @errors[name] << [ id, error_message ]
  end
  print_message("#{name} #{id}: #{error_message} #{additional_message}", true)
end

#print a message to stdout. If verbose param is set, only log if in @verbose mode
def print_message(message, verbose=false)
  if !verbose || @verbose
    print "#{message}\n"
    $stdout.flush
  end
end

def success_message(result, id)
  message = if @verbose
   "#{id}: #{result ? 'success' : 'error!'}"
  else
    result ? "." : "x"
  end
end

def print_all_errors
  @errors.each do |(name, e)|
    print_message("-----#{name} ERRORS-------")
    print_message(@errors[name].collect{|e| "#{e.first}: #{e.last}"}.join("\n"))
    print_message("-----#{name} ERROR IDS----\n#{@errors[name].collect(&:first).join(", ")}")
  end
  @errors = nil
end

def for_all_attachments(options={})
  obtain_settings
  klass = obtain_class
  names = obtain_attachments
  @errors = {} if @verbose || options[:track_errors]

  sql = klass.send(:construct_finder_sql, :select => 'id')
  sql << " #{ENV['SQL']||ENV['sql']}" if ENV['SQL']
  sql << " WHERE id = #{ENV['id']||ENV['ID']}" if ENV['id']||ENV['ID']
  ids = klass.connection.select_values(sql)

  ids.each do |id|
    instance = klass.find_by_id(id)
    next unless instance
    names.each do |name|
      begin
        print_message "#{id}: Start #{name}", true
        result = if instance.send("#{ name }?")
          yield(instance, name)
        else
          true
        end
      rescue => e
        add_error(id, name, e.inspect, ("\n#{e.backtrace.join("\n")}" if e.backtrace))
        raise e unless @skip_errors
        result = false
      end
      print_message(success_message(result, id))
      add_error(id, name, instance.errors.full_messages.inspect) if instance && !instance.errors.blank?
    end
  end
  print_message " Done."
  print_all_errors
end

namespace :paperclip do
  desc "Refreshes both metadata and thumbnails."
  task :refresh => ["paperclip:refresh:metadata", "paperclip:refresh:thumbnails"]

  namespace :refresh do
    desc "Regenerates thumbnails for a given CLASS (and optional ATTACHMENT)."
    task :thumbnails => :environment do
      for_all_attachments(:track_errors => true) do |instance, name|
        instance.send(name).reprocess!
      end
    end

    desc "Regenerates content_type/size metadata for a given CLASS (and optional ATTACHMENT)."
    task :metadata => :environment do
      for_all_attachments do |instance, name|
        if file = instance.send(name).to_file
          instance.send("#{name}_file_name=", instance.send("#{name}_file_name").strip)
          instance.send("#{name}_content_type=", file.content_type.strip)
          instance.send("#{name}_file_size=", file.size) if instance.respond_to?("#{name}_file_size")
          instance.save(false)
        else
          true
        end
      end
    end
  end

  desc "Cleans out invalid attachments. Useful after you've added new validations."
  task :clean => :environment do
    for_all_attachments do |instance, name|
      instance.send(name).send(:validate)
      if instance.send(name).valid?
        true
      else
        if @verbose && instance.errors.any?
          add_error(instance.id, name, "Cleaning invalid record: #{instance.errors.full_messages.inspect}")
        end
        instance.send("#{name}=", nil)
        instance.save
      end
    end
  end
end
