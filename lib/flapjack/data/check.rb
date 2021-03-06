#!/usr/bin/env ruby

require 'digest'

require 'sandstorm/records/redis_record'

require 'flapjack/data/validators/id_validator'

require 'flapjack/data/check_state'
require 'flapjack/data/medium'
require 'flapjack/data/scheduled_maintenance'
require 'flapjack/data/unscheduled_maintenance'
require 'flapjack/data/tag'

module Flapjack

  module Data

    class Check

      include Sandstorm::Records::RedisRecord
      include ActiveModel::Serializers::JSON
      self.include_root_in_json = false

      # NB: state could be retrieved from states.last instead -- summary, details
      # and last_update can change without a new check_state being added though

      define_attributes :name                  => :string,
                        :state                 => :string,
                        :summary               => :string,
                        :perfdata_json         => :string,
                        :details               => :string,
                        :last_update           => :timestamp,
                        :last_problem_alert    => :timestamp,
                        :enabled               => :boolean,
                        :ack_hash              => :string,
                        :initial_failure_delay => :integer,
                        :repeat_failure_delay  => :integer

      index_by :enabled, :state
      unique_index_by :name, :ack_hash

      # TODO validate uniqueness of :name, :ack_hash

      has_and_belongs_to_many :tags, :class_name => 'Flapjack::Data::Tag',
        :inverse_of => :checks

      has_sorted_set :states, :class_name => 'Flapjack::Data::CheckState', :key => :timestamp
      has_sorted_set :actions, :class_name => 'Flapjack::Data::Action', :key => :timestamp

      # keep two indices for each, so that we can query on their intersection
      has_sorted_set :scheduled_maintenances_by_start, :class_name => 'Flapjack::Data::ScheduledMaintenance',
        :key => :start_time
      has_sorted_set :scheduled_maintenances_by_end, :class_name => 'Flapjack::Data::ScheduledMaintenance',
        :key => :end_time

      has_sorted_set :unscheduled_maintenances_by_start, :class_name => 'Flapjack::Data::UnscheduledMaintenance',
        :key => :start_time
      has_sorted_set :unscheduled_maintenances_by_end, :class_name => 'Flapjack::Data::UnscheduledMaintenance',
        :key => :end_time

      # the following associations are used internally, for the notification
      # and alert queue inter-pikelet workflow
      has_many :notifications, :class_name => 'Flapjack::Data::Notification', :inverse_of => :check
      has_and_belongs_to_many :alerting_media, :class_name => 'Flapjack::Data::Medium', :inverse_of => :alerting_checks
      has_many :alerts, :class_name => 'Flapjack::Data::Alert', :inverse_of => :check

      validates :name, :presence => true
      validates :state,
        :inclusion => {:in => Flapjack::Data::CheckState.all_states, :allow_blank => true }

      validates :initial_failure_delay, :allow_blank => true,
        :numericality => {:greater_than => 0, :only_integer => true}

      validates :repeat_failure_delay, :allow_blank => true,
        :numericality => {:greater_than => 0, :only_integer => true}

      before_validation :create_ack_hash
      validates :ack_hash, :presence => true

      validates_with Flapjack::Data::Validators::IdValidator

      around_create :handle_state_change_and_enabled
      around_update :handle_state_change_and_enabled

      attr_accessor :count

      # TODO handle JSON exception
      def perfdata
        if self.perfdata_json.nil?
          @perfdata = nil
          return
        end
        @perfdata ||= JSON.parse(self.perfdata_json)
      end

      # example perfdata: time=0.486630s;;;0.000000 size=909B;;;0
      def perfdata=(data)
        if data.nil?
          self.perfdata_json = nil
          return
        end

        data = data.strip
        if data.length == 0
          self.perfdata_json = nil
          return
        end
        # Could maybe be replaced by a fancy regex
        @perfdata = data.split(' ').inject([]) do |item|
          parts = item.split('=')
          memo << {"key"   => parts[0].to_s,
                   "value" => parts[1].nil? ? '' : parts[1].split(';')[0].to_s}
          memo
        end
        self.perfdata_json = @perfdata.nil? ? nil : Flapjack.dump_json(@perfdata)
      end

      def self.jsonapi_attributes
        [:name, :initial_failure_delay, :repeat_failure_delay, :enabled]
      end

      def self.jsonapi_singular_associations
        []
      end

      def self.jsonapi_multiple_associations
        [:tags]
      end

      # takes an array of ages (in seconds) to split all checks up by
      # - age means how long since the last update
      # - 0 age is implied if not explicitly passed
      # returns arrays of all current check names hashed by age range upper bound, eg:
      #
      # EntityCheck.find_all_split_by_freshness([60, 300], opts) =>
      #   {   0 => [ 'foo-app-01:SSH' ],
      #      60 => [ 'foo-app-01:Ping', 'foo-app-01:Disk / Utilisation' ],
      #     300 => [] }
      #
      # you can also set :counts to true in options and you'll just get the counts, eg:
      #
      # EntityCheck.find_all_split_by_freshness([60, 300], opts.merge(:counts => true)) =>
      #   {   0 => 1,
      #      60 => 3,
      #     300 => 0 }
      #
      # and you can get the last update time with each check too by passing :with_times => true eg:
      #
      # EntityCheck.find_all_split_by_freshness([60, 300], opts.merge(:with_times => true)) =>
      #   {   0 => [ ['foo-app-01:SSH', 1382329923.0] ],
      #      60 => [ ['foo-app-01:Ping', 1382329922.0], ['foo-app-01:Disk / Utilisation', 1382329921.0] ],
      #     300 => [] }
      #
      def self.split_by_freshness(ages, options = {})
        raise "ages does not respond_to? :each and :each_with_index" unless ages.respond_to?(:each) && ages.respond_to?(:each_with_index)
        raise "age values must respond_to? :to_i" unless ages.all? {|age| age.respond_to?(:to_i) }

        ages << 0
        ages = ages.sort.uniq

        start_time = Time.now

        # get all the current checks, with last update time

        current_checks = Flapjack::Data::Check.intersect(:enabled => true).all

        skeleton = ages.inject({}) {|memo, age| memo[age] = [] ; memo }
        age_ranges = ages.reverse.each_cons(2)
        results_with_times = current_checks.inject(skeleton) do |memo, check|
          check_age = start_time.to_i - check.last_update
          check_age = 0 unless check_age > 0
          if check_age >= ages.last
            memo[ages.last] << "#{check.name}"
          else
            age_range = age_ranges.detect {|a, b| check_age < a && check_age >= b }
            memo[age_range.last] << "#{check.name}" unless age_range.nil?
          end
          memo
        end

        case
        when options[:with_times]
          results_with_times
        when options[:counts]
          results_with_times.inject({}) do |memo, (age, check_names)|
            memo[age] = check_names.length
            memo
          end
        else
          results_with_times.inject({}) do |memo, (age, check_names)|
            memo[age] = check_names.map { |check_name| check_name }
            memo
          end
        end
      end

      def in_scheduled_maintenance?
        return false if scheduled_maintenance_ids_at(Time.now).empty?
        self.alerting_media.each do |medium|
          self.alerting_media.delete(medium)
        end
        true
      end

      def in_unscheduled_maintenance?
        !unscheduled_maintenance_ids_at(Time.now).empty?
      end

      def handle_state_change_and_enabled
        if self.changed.include?('last_update')
          self.enabled = true
        end

        yield

        # TODO validation for: if state has changed, last_update must have changed
        return unless self.changed.include?('last_update') && self.changed.include?('state')

        # clear any alerting media if the check is OK
        if Flapjack::Data::CheckState.ok_states.include?(self.state)
          self.class.lock(Flapjack::Data::Medium) do
            self.alerting_media.each do |medium|
              self.alerting_media.delete(medium)
            end
          end
        end

        check_state = Flapjack::Data::CheckState.new(:state => self.state,
          :timestamp => self.last_update,
          :summary => self.summary,
          :details => self.details,
          :count => self.count)

        check_state.save
        self.states << check_state
      end

      def add_scheduled_maintenance(sched_maint)
        self.scheduled_maintenances_by_start << sched_maint
        self.scheduled_maintenances_by_end << sched_maint
      end

      # TODO allow summary to be changed as part of the termination
      def end_scheduled_maintenance(sched_maint, at_time)
        at_time = Time.at(at_time) unless at_time.is_a?(Time)

        if sched_maint.start_time >= at_time
          # the scheduled maintenance period is in the future
          self.scheduled_maintenances_by_start.delete(sched_maint)
          self.scheduled_maintenances_by_end.delete(sched_maint)
          sched_maint.destroy
          return true
        end

        if sched_maint.end_time >= at_time
          # it spans the current time, so we'll stop it at that point
          # need to remove it from the sorted_set that uses the end_time as a key,
          # change and re-add -- see https://github.com/ali-graham/sandstorm/issues/1
          # TODO should this be in a multi/exec block?
          self.scheduled_maintenances_by_end.delete(sched_maint)
          sched_maint.end_time = at_time
          sched_maint.save
          self.scheduled_maintenances_by_end.add(sched_maint)
          return true
        end

        false
      end

      # def current_scheduled_maintenance
      def scheduled_maintenance_at(at_time)
        current_sched_ms = scheduled_maintenance_ids_at(at_time).map {|id|
          Flapjack::Data::ScheduledMaintenance.find_by_id(id)
        }
        return if current_sched_ms.empty?
        # if multiple scheduled maintenances found, find the end_time furthest in the future
        current_sched_ms.max_by(&:end_time)
      end

      def unscheduled_maintenance_at(at_time)
        current_unsched_ms = unscheduled_maintenance_ids_at(at_time).map {|id|
          Flapjack::Data::UnscheduledMaintenance.find_by_id(id)
        }
        return if current_unsched_ms.empty?
        # if multiple unscheduled maintenances found, find the end_time furthest in the future
        current_unsched_ms.max_by(&:end_time)
      end

      def set_unscheduled_maintenance(unsched_maint)
        current_time = Time.now

        # time_remaining
        if (unsched_maint.end_time - current_time) > 0
          self.clear_unscheduled_maintenance(unsched_maint.start_time)
        end

        self.unscheduled_maintenances_by_start << unsched_maint
        self.unscheduled_maintenances_by_end << unsched_maint
        self.last_update = current_time.to_i # ack is treated as changing state in this case
        self.save

        self.class.lock(Flapjack::Data::Medium) do
          self.alerting_media.each do |medium|
            self.alerting_media.delete(medium)
          end
        end
      end

      def clear_unscheduled_maintenance(end_time)
        return unless unsched_maint = unscheduled_maintenance_at(Time.now)
        # need to remove it from the sorted_set that uses the end_time as a key,
        # change and re-add -- see https://github.com/ali-graham/sandstorm/issues/1
        # TODO should this be in a multi/exec block?
        self.unscheduled_maintenances_by_end.delete(unsched_maint)
        unsched_maint.end_time = end_time
        unsched_maint.save
        self.unscheduled_maintenances_by_end.add(unsched_maint)
      end

      def last_notification
        events = [self.unscheduled_maintenances_by_start.intersect(:notified => true).last,
                  self.states.intersect(:notified => true).last].compact

        case events.size
        when 2
          events.max_by(&:last_notification_count)
        when 1
          events.first
        else
          nil
        end
      end

      def max_notified_severity_of_current_failure
        last_recovery = self.states.intersect(:notified => true, :state => 'ok').last
        last_recovery_time = last_recovery ? last_recovery.timestamp.to_i : 0

        states_since_last_recovery =
          self.states.intersect_range(last_recovery_time, nil, :by_score => true).
            collect(&:state).uniq

        ['critical', 'warning', 'unknown'].detect {|st| states_since_last_recovery.include?(st) }
      end


      # candidate rules are all rules for which
      #   (rule.tags.ids - check.tags.ids).empty?
      # this includes generic rules, i.e. ones with no tags

      # A generic rule in Flapjack v2 means that it applies to all checks, not
      # just all checks the contact is separately regeistered for, as in v1.
      # These are not automatically created for users any more, but can be
      # deliberately configured.

      # returns hash with check_id => [rules_ids]
      def self.rules_for(*check_ids)
        generic_rules_ids = Flapjack::Data::Rule.intersect(:is_specific => false).ids

        tag_ids_by_check_id = Flapjack::Data::Check.intersect(:id => check_ids).
          associated_ids_for(:tags)

        tag_ids_by_check_id.each_with_object({}) do |(check_id, tag_ids), memo|
          tag_rules_ids = Flapjack::Data::Tag.intersect(:id => tag_ids).
            associated_ids_for(:rules)

          all_rules_for_tags_ids = Set.new(tag_rules_ids.values).flatten

          rule_tags_ids = Flapjack::Data::Rule.intersect(:id => all_rules_for_tags_ids).
            associated_ids_for(:tags)

          rule_tags_ids.delete_if {|rid, tids| (tids - tag_ids).size > 0 }

          memo[check_id] = rule_tags_ids.keys | generic_rules_ids.to_a
        end
      end

      # returns hash with contact_id => [route_ids]
      def routes_for(opts = {})
        severity = opts[:severity]
        logger   = opts[:logger]

        rules_ids_by_check_id = Flapjack::Data::Check.rules_for(*self.id)

        rules_ids = rules_ids_by_check_id[self.id]

        return [] if rules_ids.empty?

        rule_route_ids = Flapjack::Data::Rule.intersect(:id => rules_ids).
          associated_ids_for(:routes)

        return [] if rule_route_ids.empty?

        # unrouted rules should be dropped
        rule_route_ids.delete_if {|nr_id, route_ids| route_ids.empty? }
        return [] if rule_route_ids.empty?

        route_ids_for_all_states = Set.new(rule_route_ids.values).flatten

        # TODO sandstorm should accept a set as well as an array in intersect
        active_route_ids = if severity.nil?
          Flapjack::Data::Route.
            intersect(:id => route_ids_for_all_states).ids
        else
          Flapjack::Data::Route.
            intersect(:id => route_ids_for_all_states, :state => [nil, severity]).ids
        end

        logger.info "Matching routes: #{active_route_ids.size}"

        return [] if active_route_ids.empty?

        # if more than one route exists for a rule & state, media will be unioned together
        # (may happen with, e.g. overlapping time restrictions, multiple matching rules, etc.)

        # TODO is it worth doing a shortcut check here -- if no media for routes, return [] ?

        # TODO possibly invert the returned data from associated_ids_for belongs_to?
        # we're always doing it on this side anyway
        rule_ids_by_route_id = Flapjack::Data::Route.intersect(:id => active_route_ids).
          associated_ids_for(:rule)

        unified_rule_ids = Set.new(rule_ids_by_route_id.values).flatten

        contact_ids_by_rule_id = Flapjack::Data::Rule.intersect(:id => unified_rule_ids).
          associated_ids_for(:contact)

        rule_ids_by_route_id.inject({}) do |memo, (route_id, rule_id)|
          memo[contact_ids_by_rule_id[rule_id]] ||= []
          memo[contact_ids_by_rule_id[rule_id]] << route_id
          memo
        end
      end

      def self.pagerduty_credentials_for(check_ids)
        rule_ids_by_check_id = Flapjack::Data::Check.rules_for(check_ids)

        route_ids_by_media_id = Flapjack::Data::Medium.
          intersect(:transport => 'pagerduty').associated_ids_for(:routes)

        return nil if route_ids_by_media_id.empty? ||
          route_ids_by_media_id.values.all? {|r| r.empty? }

        route_ids = Set.new(route_ids_by_media_id.values).flatten

        media_ids_by_route_id = Flapjack::Data::Route.
          intersect(:id => route_ids).associated_ids_for(:media)

        route_ids_by_rule_id = Flapjack::Data::Route.intersect(:id => route_ids)
          .associated_ids_for(:rule, :inversed => true)

        pagerduty_objs_by_id = Flapjack::Data::Medium.find_by_ids!(route_ids_by_media_id.keys)

        Flapjack::Data::Check.intersect(:id => check_ids).all.each_with_object({}) do |check, memo|
          memo[check] = rule_ids_by_check_id[check.id].each_with_object([]) do |rule_id, m|
            m[rule_id] = route_ids_by_rule_id[rule_id].each_with_object([]) do |route_id, mm|
              mm += media_ids_by_route_id[route_id].collect do |media_id|
                medium = pagerduty_objs_by_id[media_id]
                ud = medium.userdata || {}
                {
                  'service_key' => medium.address,
                  'subdomain'   => ud['subdomain'],
                  'username'    => ud['username'],
                  'password'    => ud['password'],
                }
              end
            end
          end
        end
      end

      private

      # would need to be "#{entity.name}:#{name}" to be compatible with v1, but
      # to support name changes it must be something invariant
      def create_ack_hash
        return unless self.ack_hash.nil? # :on => :create isn't working
        self.id = self.class.generate_id if self.id.nil?
        self.ack_hash = Digest.hexencode(Digest::SHA1.new.digest(self.id))[0..7].downcase
      end

      def scheduled_maintenance_ids_at(at_time)
        at_time = Time.at(at_time) unless at_time.is_a?(Time)

        start_prior_ids = self.scheduled_maintenances_by_start.
          intersect_range(nil, at_time.to_i, :by_score => true).ids
        end_later_ids = self.scheduled_maintenances_by_end.
          intersect_range(at_time.to_i + 1, nil, :by_score => true).ids

        start_prior_ids & end_later_ids
      end

      def unscheduled_maintenance_ids_at(at_time)
        at_time = Time.at(at_time) unless at_time.is_a?(Time)

        start_prior_ids = self.unscheduled_maintenances_by_start.
          intersect_range(nil, at_time.to_i, :by_score => true).ids
        end_later_ids = self.unscheduled_maintenances_by_end.
          intersect_range(at_time.to_i + 1, nil, :by_score => true).ids

        start_prior_ids & end_later_ids
      end

    end

  end

end
