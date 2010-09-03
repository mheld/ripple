# Copyright 2010 Sean Cribbs, Sonian Inc., and Basho Technologies, Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
require 'ripple'

module Ripple
  
  # Raised by <tt>find!</tt> when a document cannot be found with the given key.
  #   begin
  #     Example.find!('badkey')
  #   rescue Ripple::DocumentNotFound
  #     puts 'No Document here!'
  #   end
  class DocumentNotFound < StandardError
    include Translation
    def initialize(keys, found)
      if keys.empty?
        super(t("document_not_found.no_key"))
      elsif keys.one?
        super(t("document_not_found.one_key", :key => keys.first))
      else
        missing = keys - found.compact.map(&:key)
        super(t("document_not_found.many_keys", :keys => missing.join(', ')))
      end
    end
  end
  
  module Document
    module Finders
      extend ActiveSupport::Concern

      module ClassMethods
        # Retrieve single or multiple documents from Riak.
        # @overload find(key)
        #   Find a single document.
        #   @param [String] key the key of a document to find
        #   @return [Document] the found document, or nil
        # @overload find(:where, cond...)
        #   Find a list of documents.
        #   @param [Symbol] where the position to find the document in
        #   @param [Hash] cond the conditions to satisfy
        #   @return [Array<Document>] a list of found documents, including nil for missing documents
        # If a String is provided, it will be assumed that it is a key and will 
        # attempt to find a single Document based on that id. If a Symbol and 
        # Hash is provided then it will attempt to find either a single 
        # Document or multiples based on the conditions provided and the first
        # parameter.
        #
        # <tt>Person.find(:first, :conditions => { :attribute => "value" })</tt>
        #
        # <tt>Person.find(:all, :conditions => { :attribute => "value" })</tt>
        def find(*args)
          raise Errors::InvalidOptions.new("Calling Document#find with nil is invalid") if args[0].nil?
          type = args.delete_at(0) if args[0].is_a?(Symbol)
          case type
            when :first then return all(*args)[0]
            when :last then return criteria.last
          else
            return all(*args)
          end
        end
        
        # Retrieve single or multiple documents from Riak
        # but raise Ripple::DocumentNotFound if a key can
        # not be found in the bucket.
        def find!(*args)
          found = find(*args)
          raise DocumentNotFound.new(args, found) if !found || Array(found).include?(nil)
          found
        end
        
        # Find the first object using the first key in the
        # bucket's keys using find. You should not expect to 
        # actually get the first object you added to the bucket.
        # This is just a convenience method.
        def first(*args)
          find(bucket.keys.first)
        end
        
        # Find the first object using the first key in the
        # bucket's keys using find!
        def first!
          find!(bucket.keys.first)
        end

        # Find all documents in the Document's bucket and return them.
        # @overload all()
        #   Get all documents and return them in an array.
        #   @return [Array<Document>] all found documents in the bucket
        # @overload all() {|doc| ... }
        #   Stream all documents in the bucket through the block.
        #   @yield [Document] doc a found document
        # @overload all(:conditions => {conditions})
        #   Gets all documents that satisfy the given conditions
        #   @return [Array<Document>] all found documents in the bucket
        def all(args = {})
          if args.length == 0
            if block_given?
              bucket.keys do |keys|
                keys.each do |key|
                  obj = find_one(key)
                  yield obj if obj
                end
              end
              []
            else
              bucket.keys.inject([]) do |acc, k|
                obj = find_one(k)
                obj ? acc << obj : acc
              end
            end
          else
            objectize(query(args[:conditions]))
          end
        end

        private
        def find_or(method, attrs = {})
          first(:conditions => attrs) || send(method, attrs)
        end
        
        def query(hash)
          str = ""
          hash.each{|k,v| str << "data[0].#{k} == '#{v}' && "}
          str << "true"
          mr = Riak::MapReduce.new(Ripple.client)
          .add(self.bucket)
          .map("function(v){ var data = Riak.mapValuesJson(v); if(#{str}){return [data];}else{return [];}}",
          :keep => true)
          mr.run[0] || []
        end

        # converts arrays to objects, assuming that _type is the name of the class to create
        # ar - an array of hashes returned by
        def objectize(ar)
          ar.map do |e|
            klass = e["_type"]
            klass.constantize.new(e.except(klass))
          end
        end
        
        def find_one(key)
          instantiate(bucket.get(key, quorums.slice(:r)))
        rescue Riak::FailedRequest => fr
          return nil if fr.code.to_i == 404
          raise fr
        end

        def instantiate(robject)
          klass = robject.data['_type'].constantize rescue self
          data = {'key' => robject.key}
          data.reverse_merge!(robject.data) rescue data
          klass.new(data).tap do |doc|
            doc.key = data['key']
            doc.instance_variable_set(:@new, false)
            doc.instance_variable_set(:@robject, robject)
          end
        end
      end
    end
  end
end
