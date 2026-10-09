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
