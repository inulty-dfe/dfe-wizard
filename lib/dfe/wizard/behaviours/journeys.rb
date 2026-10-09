module DfE
  module Wizard
    module Behaviours
      # Change journeys from check answers.
      #
      # Turned on by `graph.check_answers` in a Graph wizard. A wizard that
      # does not declare it behaves as in 1.0.
      #
      # @api public
      module Journeys
        # The wizard's changeset
        #
        # Memoised per wizard instance. Building it reads and writes nothing.
        #
        # @return [DfE::Wizard::Changeset]
        def changeset
          @changeset ||= Changeset.new(self)
        end

        # The current answers for the steps on the full path
        #
        # Step attributes only, with their raw values, in attribute_names
        # order. Answers for steps that left the path are not included.
        #
        # @return [Hash{Symbol => Object}]
        def answers_on_path
          definitions = step_definitions
          on_path = full_path.flat_map do |step_id|
            step_class = definitions[step_id]
            step_class.respond_to?(:attribute_names) ? step_class.attribute_names.map(&:to_sym) : []
          end
          read = state_store.read

          attribute_names.map(&:to_sym).uniq.each_with_object({}) do |name, answers|
            next unless on_path.include?(name)

            if read.key?(name)
              answers[name] = read[name]
            elsif read.key?(name.to_s)
              answers[name] = read[name.to_s]
            end
          end
        end

        # Start a change journey on a GET that carries the start param
        #
        # Call it at the top of the step's GET action. When the request
        # carries `return_to_review=<step_id>` and the wizard declares
        # `graph.check_answers`, it starts (or restarts) the journey for the
        # step's unit and returns the path of the unit's first step on the
        # path, without the param. Redirect to it.
        #
        # @return [String, nil] the path to redirect to, or nil
        # @raise [ArgumentError] when the repository cannot hold a changeset
        #
        # @example
        #   def show
        #     redirect = @wizard.journey_start_redirect
        #     redirect_to(redirect) if redirect
        #   end
        def journey_start_redirect
          return unless journeys?

          journey.start_redirect
        end

        # Whether the wizard declares graph.check_answers
        #
        # @return [Boolean]
        def journeys?
          !cached_steps_processor.check_answers_step.nil?
        end

        # @return [DfE::Wizard::Journey]
        # @api private
        def journey
          @journey ||= Journey.new(self)
        end

        # The params the wizard was built with, unfiltered
        #
        # @return [Hash, ActionController::Parameters, nil]
        # @api private
        def raw_step_params
          @current_step_params
        end
      end
    end
  end
end
