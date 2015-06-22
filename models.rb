require 'nokogiri'

module AccountScoped
  extend ActiveSupport::Concern

  included do
    include Mongoid::Document
    store_in collection: Proc.new { Account.tenant_collection_name(to_s) }
  end
end

class User

end

class Account
  include Mongoid::Document

  belongs_to :owner, class_name: User.to_s, inverse_of: nil
  has_many :users, class_name: User.to_s, inverse_of: :account

  class << self
    def current
      Thread.current[:current_account]
    end

    def tenant_collection_prefix(sep = '')
      current.present? ? "acc#{current.id}#{sep}" : ''
    end

    def tenant_collection_name(model_name, sep='_')
      tenant_collection_prefix(sep) + model_name.collectionize
    end
  end
end

class User
  include Mongoid::Document

  field :unique_key, type: String

  belongs_to :account, inverse_of: :users, class_name: Account.to_s
end

module Setup

  class Library
    include AccountScoped

    field :slug, type: String
  end

  class Validator
    include AccountScoped
  end

  class Schema < Validator

    belongs_to :library, class_name: Setup::Library.to_s, inverse_of: :schemas

    field :uri, type: String
    field :schema, type: String
    field :schema_type, type: Symbol

    def cenit_ref_schema(options = {})
      send("cenit_ref_#{schema_type}", options)
    end

    def cenit_ref_json_schema(options = {})
      schema
    end

    def cenit_ref_xml_schema(options = {})
      doc = Nokogiri::XML(schema)
      cursor = doc.root.first_element_child
      while cursor
        if %w(import include redefine).include?(cursor.name) && (attr = cursor.attributes['schemaLocation'])
          attr.value = options[:service_url].to_s + '?' + {
              key: Account.current.owner.unique_key,
              library_id: library.id.to_s,
              uri: attr.value
          }.to_param
        end
        cursor = cursor.next_element
      end
      doc.to_xml
    end

  end
end