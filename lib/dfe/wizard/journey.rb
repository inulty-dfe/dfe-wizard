module DfE
  module Wizard
    # Change journey navigation for a wizard that declares
    # `graph.check_answers`.
    #
    # A journey starts on the GET that carries `return_to_review=<step_id>`
    # (#start_redirect). It shows the step's unit, then each later unit on
    # the path whose `depends_on` names an answer that changed since the
    # start, then returns to the check answers node.
    #
    # State changes only in #start_redirect and #after_save.
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

        caller_step
      end

      private

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

      def caller_step
        graph.check_answers_step
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
