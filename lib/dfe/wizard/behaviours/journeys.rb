module DfE
  module Wizard
    module Behaviours
      # Change journeys from check answers, and edits of saved records.
      #
      # Turned on by `graph.check_answers` in a Graph wizard. A wizard that
      # does not declare it behaves as in 1.0.
      #
      # @api public
      module Journeys
        # The saved record of an edit, given to `new` as `record:`
        #
        # @return [Object, nil] nil on a draft
        attr_reader :record

        # The wizard's changeset
        #
        # Memoised per wizard instance. Building it reads and writes nothing
        # for a wizard that neither edits nor declares graph.check_answers.
        # Otherwise the first call checks that the changeset matches the
        # request: it reads the store once and never walks the graph.
        #
        # @return [DfE::Wizard::Changeset]
        # @raise [ChangesetExpired] built with `record:` and the changeset
        #   holds no edit
        # @raise [ChangesetMismatch] the changeset is an edit of another
        #   record, or an edit and the request has no `record:`
        def changeset
          @changeset ||= Changeset.new(self)
          unless @changeset_checked
            @changeset.check_mode!(record) if editing? || journeys?
            @changeset_checked = true
          end
          @changeset
        end

        # Whether this request edits a saved record (built with `record:`)
        #
        # @return [Boolean]
        def editing?
          !record.nil?
        end

        # The mapper that seeds an edit from the saved record
        #
        # Override it to edit saved records. It must respond to
        # `to_answers(record)`.
        #
        # @return [#to_answers, nil] nil by default
        def mapper
          nil
        end

        # Start an edit of the saved record
        #
        # Call it at the edit entry point, on a wizard built with `record:`
        # and a new state_key. It seeds the changeset with
        # `mapper.to_answers(record)`, keeps the record's `updated_at`, its
        # identity and the caller URL, and starts a change journey for the
        # unit. Redirect to the step it returns.
        #
        # @param unit [Symbol] a unit id (a sub-wizard id or a step id)
        # @param caller [String] the URL to return to when the edit ends
        # @return [Symbol] the first step to show
        # @raise [ArgumentError] without `record:`, `graph.check_answers`, a
        #   mapper or an `on_commit` operation; for an unknown unit; or for a
        #   repository that cannot hold a changeset
        # @raise [NotCallable] when the unit has no step on the path
        #
        # @example
        #   wizard = CourseWizard.new(state_store:, record: course)
        #   step = wizard.start_edit(unit: :funding_type, caller: course_path)
        #   redirect_to wizard.resolve_step_path(step)
        def start_edit(unit:, caller:)
          raise ArgumentError, 'start_edit needs a wizard built with record:' unless editing?
          raise ArgumentError, 'edits need graph.check_answers' unless journeys?
          raise ArgumentError, 'edits need a mapper' if mapper.nil?
          raise ArgumentError, 'edits need builder.on_commit' if steps_operator.commit_operations.empty?

          @changeset ||= Changeset.new(self)
          @changeset_checked = true
          journey.start_edit(unit_id: unit.to_sym, caller_url: caller)
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

        # Whether a step may be shown or saved in this request
        #
        # Always true on a draft. In an edit, true when the step is on the
        # path and in the journey's current unit or a unit it has shown.
        #
        # @param step_id [Symbol]
        # @return [Boolean]
        #
        # @example Guard a GET in an edit
        #   redirect_to wizard.resolve_step_path(wizard.redirect_step) unless wizard.step_accessible?(step)
        def step_accessible?(step_id)
          return true unless editing?

          journey.shows?(step_id.to_sym)
        end

        # Where to send a request for a step that is not accessible
        #
        # @return [Symbol, nil] the first step on the path of the journey's
        #   current unit, or nil when there is no journey
        def redirect_step
          journey.current_unit_first_step
        end

        # The result of the commit, in the request whose save ended an edit
        #
        # The changeset is discarded after every commit, whatever the status.
        #
        # @return [Hash, nil] `{ status:, errors: }`, with status
        #   `:committed`, `:unchanged` (no answer on the path differs from
        #   the seed; no operation ran), `:stale` (the record changed since
        #   it was seeded; no operation ran) or `:failed` (an operation
        #   returned no success), and errors as full messages; nil in every
        #   other request
        attr_reader :commit_result

        # The next step; nil once this request's save ended an edit
        #
        # @return [Symbol, nil]
        def next_step
          return if edit_finished?

          super
        end

        # The next step's path; the caller URL once this request's save
        # ended an edit
        #
        # @return [String, nil]
        def next_step_path(options = {})
          return @edit_caller_url if edit_finished?

          super
        end

        # The previous step; nil when Back leaves an edit for its caller
        #
        # @return [Symbol, nil]
        def previous_step
          return if edit_back_to_caller?

          super
        end

        # The previous step's path; the caller URL when Back leaves an edit
        #
        # @return [String, nil]
        def previous_step_path(fallback: nil, **options)
          return changeset.caller_url if edit_back_to_caller?

          super
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
          return if !journeys? || editing?

          journey.start_redirect
        end

        # Whether the wizard declares graph.check_answers
        #
        # @return [Boolean]
        def journeys?
          !cached_steps_processor.check_answers_step.nil?
        end

        # Run the commit of an edit and discard the changeset
        #
        # Called by save_current_step when its save ended an edit.
        #
        # @return [void]
        # @api private
        def commit_edit
          @edit_caller_url = changeset.caller_url
          @commit_result = run_commit_operations
          changeset.discard!
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

        private

        def edit_finished?
          editing? && journeys? && journey.finished?
        end

        def edit_back_to_caller?
          editing? && journeys? && !journey.finished? && journey.back_to_caller?
        end

        def run_commit_operations
          return { status: :unchanged, errors: [] } unless changeset.diff?
          return { status: :stale, errors: [] } if changeset.stale?(record)

          steps_operator.commit_operations.each do |operation_class|
            result = execute_operation(operation_class:, step: current_step)
            return { status: :failed, errors: commit_errors(result) } unless result && result[:success]
          end

          { status: :committed, errors: [] }
        end

        def commit_errors(result)
          errors = result && result[:errors]
          return errors.full_messages if errors.respond_to?(:full_messages)
          return errors.values.flatten.map(&:to_s) if errors.is_a?(Hash)

          Array(errors).map(&:to_s)
        end
      end
    end
  end
end
