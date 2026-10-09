module DfE
  module Wizard
    # Change journey navigation for a wizard that declares
    # `graph.check_answers`.
    #
    # A journey starts on the GET that carries `return_to_review=<step_id>`
    # (#start_redirect), or, for an edit of a saved record, in #start_edit.
    # It shows the step's unit, then each later unit on the path whose
    # `depends_on` names an answer that changed since the start, then
    # returns to the caller: the check answers node on a draft, the caller
    # URL in an edit.
    #
    # State changes only in #start_redirect, #start_edit and #after_save.
    # #next_step and #previous_step are the gem's before_next_step and
    # before_previous_step callbacks: they read state and never write.
    #
    # Stored state (in the changeset, under :journey):
    # - unit: the unit being shown;
    # - shown: units already shown in this journey, in order;
    # - snapshot: the answers at the start.
    #
    # @api private
    class Journey
      START_PARAM = :return_to_review

      # Back target meaning "the caller", which is a URL in an edit
      CALLER = :_dfe_wizard_caller

      # @param wizard [DfE::Wizard]
      def initialize(wizard)
        @wizard = wizard
        @finished = false
      end

      # Start a journey when the request carries the start param
      #
      # Every start restarts the journey: the old state is replaced.
      #
      # @return [String, nil] the path to redirect to, or nil when the
      #   request does not start a journey
      def start_redirect
        unit = start_unit
        return unless unit

        first_step = unit_steps_on(@wizard.full_path, unit).first
        if first_step.nil?
          changeset.journey = nil
          return @wizard.resolve_step_path(caller_step)
        end

        changeset.journey = { unit: unit.id, shown: [], snapshot: changeset.answers }
        @wizard.resolve_step_path(first_step)
      end

      # Start the journey of an edit of a saved record
      #
      # Seeds the changeset from the wizard's record and mapper, stores the
      # record identity and the caller URL, then starts a journey for the
      # unit.
      #
      # @param unit_id [Symbol] a unit id, or a step id in the unit
      # @param caller_url [String]
      # @return [Symbol] the unit's first step on the path
      # @raise [ArgumentError] for an unknown unit
      # @raise [NotCallable] when the unit has no step on the path
      def start_edit(unit_id:, caller_url:)
        unit = graph.unit(unit_id)
        raise ArgumentError, "#{unit_id.inspect} is not a unit or a step" unless unit

        record = @wizard.record
        changeset.seed!(@wizard.mapper.to_answers(record), updated_at: record.updated_at)
        changeset.identify!(record:, caller_url:)

        first_step = unit_steps_on(@wizard.full_path, unit).first
        unless first_step
          changeset.discard!
          raise NotCallable, "unit #{unit.id.inspect} has no step on the path for this record"
        end

        changeset.journey = { unit: unit.id, shown: [], snapshot: changeset.answers }
        first_step
      end

      # Whether the save in this request ended the journey
      #
      # @return [Boolean]
      def finished?
        @finished
      end

      # Whether Back from the current step leaves the journey for its caller
      #
      # @return [Boolean]
      def back_to_caller?
        back_target == CALLER
      end

      # Whether the journey shows a step: the step is on the path, and its
      # unit is the current unit or a shown unit. The check answers node is
      # never shown.
      #
      # @param step_id [Symbol]
      # @return [Boolean]
      def shows?(step_id)
        state = changeset.journey
        unit = graph.unit_for(step_id)
        return false unless state && unit

        units = [state[:unit].to_sym] + shown_units(state)
        units.include?(unit.id) && @wizard.full_path.include?(step_id)
      end

      # The first step on the path of the current unit
      #
      # @return [Symbol, nil] nil when there is no journey
      def current_unit_first_step
        state = changeset.journey
        return unless state

        unit_steps_on(@wizard.full_path, graph.unit(state[:unit].to_sym)).first
      end

      # Called by save_current_step after the step's operations succeed
      #
      # - A save on a step outside the journey changes nothing; navigation
      #   is as in 1.0.
      # - A save in a unit already shown (the user went Back into it) makes
      #   that unit current again, and forgets it and every later shown unit.
      # - A save on the unit's last step on the path ends the unit: the
      #   next unit is the first later unit on the path, not yet shown, whose
      #   depends_on names a changed answer. With none, the journey ends.
      #
      # @return [void]
      def after_save
        state = changeset.journey
        unit = current_unit
        return unless state && unit

        shown = shown_units(state)
        if shown.include?(unit.id)
          shown = shown.take(shown.index(unit.id))
        elsif unit.id != state[:unit].to_sym
          return
        end

        path = @wizard.full_path
        if later_step_in_unit(path, unit)
          changeset.journey = state.merge(unit: unit.id, shown:)
          return
        end

        shown += [unit.id]
        next_unit = queued_units(path, unit, shown, changeset.answer_changes_since(state[:snapshot])).first
        if next_unit
          changeset.journey = state.merge(unit: next_unit.id, shown:)
        else
          changeset.journey = nil
          @finished = true
        end
      end

      # The gem's before_next_step callback
      #
      # @return [Symbol, nil] nil to use 1.0 navigation
      def next_step
        return caller_step if @finished

        state = changeset.journey
        unit = current_unit
        return unless state && unit

        path = @wizard.full_path
        return later_step_in_unit(path, unit) if unit.id == state[:unit].to_sym
        return unless shown_units(state).include?(unit.id)

        unit_steps_on(path, graph.unit(state[:unit].to_sym)).first
      end

      # The gem's before_previous_step callback
      #
      # Inside a unit, Back goes to the previous step of the unit on the
      # path. On its first step, Back goes to the last step of the unit
      # shown before it, and on the first unit to the check answers node.
      #
      # @return [Symbol, nil] nil to use 1.0 navigation
      def previous_step
        target = back_target
        target == CALLER ? caller_step : target
      end

      private

      # The Back target: a step id, CALLER, or nil outside the journey
      def back_target
        state = changeset.journey
        unit = current_unit
        return unless state && unit

        shown = shown_units(state)
        active = unit.id == state[:unit].to_sym
        return unless active || shown.include?(unit.id)

        path = @wizard.full_path
        steps = unit_steps_on(path, unit)
        index = steps.index(current_step_name)
        return steps[index - 1] if index&.positive?

        earlier = active ? shown : shown.take(shown.index(unit.id))
        earlier.reverse_each do |unit_id|
          last_step = unit_steps_on(path, graph.unit(unit_id)).last
          return last_step if last_step
        end

        CALLER
      end

      def start_unit
        step_id = start_param
        return unless step_id

        graph.unit_for(step_id)
      end

      def start_param
        params = @wizard.raw_step_params
        return unless params.respond_to?(:[])

        value = params[START_PARAM] || params[START_PARAM.to_s]
        value.presence&.to_sym
      end

      def current_unit
        graph.unit_for(current_step_name)
      end

      def current_step_name
        @wizard.current_step_name
      end

      # The check answers node on a draft. Nil in an edit: its caller is a
      # URL, which the wizard returns from next_step_path and
      # previous_step_path.
      def caller_step
        graph.check_answers_step unless @wizard.editing?
      end

      def shown_units(state)
        Array(state[:shown]).map(&:to_sym)
      end

      def unit_steps_on(path, unit)
        return [] unless unit

        path.select { |step_id| unit.step_ids.include?(step_id) }
      end

      def later_step_in_unit(path, unit)
        steps = unit_steps_on(path, unit)
        index = steps.index(current_step_name)
        index ? steps[index + 1] : nil
      end

      def queued_units(path, unit, shown, changed)
        units = path.filter_map { |step_id| graph.unit_for(step_id) }.uniq(&:id)
        units.drop_while { |candidate| candidate.id != unit.id }.drop(1).select do |candidate|
          !shown.include?(candidate.id) && candidate.depends_on.intersect?(changed)
        end
      end

      def changeset
        @wizard.changeset
      end

      # The wizard's cached graph (private in DfE::Wizard)
      def graph
        @wizard.send(:cached_steps_processor)
      end
    end
  end
end
