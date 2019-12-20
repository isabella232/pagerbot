module PagerBot
  # This class takes action/prepares response based on parsed queries.
  class ActionManager
    extend MethodDecorators

    include SemanticLogger::Loggable

    attr_reader :pagerduty, :plugin_manager, :current_adapter

    def initialize(options)
      @options = options
      @pagerduty = PagerBot::PagerDuty.new(options.fetch(:pagerduty))
      @plugin_manager = PagerBot::PluginManager.new(options[:plugins] || {})
    end

    # Send the parsed query to the correct function/plugin
    # Will return a hash in the following form
    # {
    #   message => "Message to be sent in the channel",
    #   private_message => "Message to be send in pm"
    # }
    def dispatch(parsed_query, event_data)
      @current_adapter = event_data[:adapter]

      # Try to get answer from plugins
      if parsed_query[:plugin]
        begin
          response = plugin_manager.dispatch(
            parsed_query[:plugin], parsed_query, event_data)
        rescue Exception => e
          message = "Hmm, that didn't seem to work: #{e.message}"
          info = PluginManager.info(parsed_query[:plugin])
          if info[:syntax]
            message << "\nSyntax: #{info[:syntax].first}"
          end
          response = {message: message}

          logger.error "Failed to process message.", e
        end
      else
        begin
          # Call method on this class by type field indicated by parser output.
          # Note that this wouldn't cause any problems as long as long as
          # parser doesn't output :type => :freeze or similar
          method = parsed_query[:type].gsub(/[- ]/, '_')
          response = self.send method, parsed_query, event_data
        rescue Exception => e
          response = {message: "Hmm, that didn't seem to work: #{e.message}"}
          logger.error "Failed to process message.", e
        end
      end
      response
    end

    +PagerBot::Utilities::DispatchMethod
    def hello(query, event_data={})
      "Hello, #{event_data[:nick]} - my npm friend!"
    end

    # because who doesn't like one-liners. Feel free to refactor!
    +PagerBot::Utilities::DispatchMethod
    def list_schedules(query, event_data={})
      message = render('list', {
        collection_name: 'schedules',
        collection: @pagerduty.schedules.list,
        aliases_extractor: lambda { |member| Utilities.pluck('name', member.aliases).sort }
      })
      { private_message: message }
    end

    +PagerBot::Utilities::DispatchMethod
    def list_people(query, event_data={})
      message = render('list', {
        collection_name: 'people',
        collection: @pagerduty.users.list,
        aliases_extractor: lambda { |member| Utilities.pluck('name', member.aliases).sort }
      })
      { private_message: message }
    end

    +PagerBot::Utilities::DispatchMethod
    def manual(query, event_data)
      {
        message: "Sending you the manual in a PM.",
        private_message: render('manual', loaded_plugins: plugin_manager.loaded_plugins, name: @options[:bot][:name])
      }
    end

    +PagerBot::Utilities::DispatchMethod
    def help(query, event_data)
      render(
        'help',
        loaded_plugins: plugin_manager.loaded_plugins,
        name: @options[:bot][:name])
    end

    +PagerBot::Utilities::DispatchMethod
    def lookup_time(query, event_data)
      # who is on primary?
      schedule = @pagerduty.find_schedule(query[:schedule])
      time = @pagerduty.parse_time(query[:time], event_data[:nick], guess: :middle)
      oncall_users = @pagerduty.get_schedule_oncall(schedule.id, time)
      vars = {
        schedule: schedule,
        start: time,
        person: nil
      }
      if oncall_users.length > 0
        vars[:person] = @pagerduty.users.get(oncall_users[0][:id])
      end
      render "lookup_time", vars
    end

    +PagerBot::Utilities::DispatchMethod
    def lookup_person(query, event_data)
      # when am i on primary breakage

      person = @pagerduty.find_user(query[:person], event_data[:nick])

      # :TRICKY: Special case "call" - this will return the next time the
      #   person goes on any on call.
      if query[:schedule] == 'call'
        next_oncall = @pagerduty.next_oncall(person.id, nil)
        if next_oncall[:schedule].nil?
          schedule = nil
          next_oncall = nil
        else
          schedule = @pagerduty.find_schedule(next_oncall[:schedule][:name])
        end
      else
        schedule = @pagerduty.find_schedule(query[:schedule])
        next_oncall = @pagerduty.next_oncall(person.id, schedule.id)
      end

      output_data = {
        time: nil,
        person: person,
        schedule: schedule
      }
      unless next_oncall.nil?
        output_data[:time] = person.parse_time(next_oncall[:start])
      end

      render "lookup_person", output_data
    end

    +PagerBot::Utilities::DispatchMethod
    def no_such_command(query, event_data)
      "Hmm, I don't understand that command. Maybe you should ask for help?"
    end

    def render(template, variables)
      PagerBot::Template.render(template, variables)
    end
  end
end
