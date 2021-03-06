#!/usr/bin/env ruby

require 'sandstorm/records/redis_record'

require 'flapjack/data/validators/id_validator'

require 'flapjack/data/alert'
require 'flapjack/data/check'

module Flapjack

  module Data

    class Medium

      include Sandstorm::Records::RedisRecord
      include ActiveModel::Serializers::JSON
      self.include_root_in_json = false

      TRANSPORTS = ['email', 'sms', 'jabber', 'pagerduty', 'sns', 'sms_twilio']

      define_attributes :transport         => :string,
                        :address           => :string,
                        :interval          => :integer,
                        :rollup_threshold  => :integer,
                        # :userdata          => :hash,
                        :last_rollup_type  => :string,
                        :last_notification => :timestamp,
                        :last_notification_state => :string

      belongs_to :contact, :class_name => 'Flapjack::Data::Contact',
        :inverse_of => :media

      has_and_belongs_to_many :routes, :class_name => 'Flapjack::Data::Route',
        :inverse_of => :media

      has_many :alerts, :class_name => 'Flapjack::Data::Alert', :inverse_of => :medium
      has_and_belongs_to_many :alerting_checks, :class_name => 'Flapjack::Data::Check',
        :inverse_of => :alerting_media

      index_by :transport

      validates :transport, :presence => true,
        :inclusion => {:in => Flapjack::Data::Medium::TRANSPORTS }
      validates :address, :presence => true
      validates :interval, :presence => true,
        :numericality => {:greater_than_or_equal_to => 0, :only_integer => true}
      validates :rollup_threshold, :allow_blank => true,
        :numericality => {:greater_than => 0, :only_integer => true}

      validates_with Flapjack::Data::Validators::IdValidator

      def self.jsonapi_attributes
        [:transport, :address, :interval, :rollup_threshold]
      end

      def self.jsonapi_singular_associations
        [:contact]
      end

      def self.jsonapi_multiple_associations
        [:routes]
      end
    end
  end
end