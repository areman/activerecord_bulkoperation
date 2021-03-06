module ActiveRecord
    class NoPersistentRecord < ActiveRecordError
  end

  class NoOrginalRecordFound < ActiveRecordError
  end

  class ExternalDataChange < ActiveRecordError
  end

  class Base
    extend ActiveRecord::Bulkoperation::BatchUpdate::InstanceMethods
    class << self
      def flush_scheduled_operations(args = {})
        ActiveRecord::Bulkoperation::Util::FlushDirtyObjects.get.flush_record_class(self, args)
      end

      def has_id_column?
        @has_id_column ||= columns_hash.key?('id')# and oracle?
      end

      def sequence_exists?(name)
        connection.find_by_sequence_name_sql_array(name).nil? == false
      end


      def check_sequence
        if sequence_exists?("#{table_name}_seq")
          "#{table_name}_seq"
        else
          sequence_name
        end
      end

      def next_sequence_value
        @sequence_cache ||= ActiveRecord::Bulkoperation::Util::SequenceCache.new(check_sequence)
        @sequence_cache.next_value
      end

      def find_foreign_master_tables
        arr = connection.find_foreign_master_tables_sql_array(table_name)
        sql = sanitize_sql(arr)
        Array(find_by_sql(sql)).map { |e|e.table_name }
      end

      def find_foreign_detail_tables
        arr = connection.find_foreign_detail_tables_sql_array(table_name)
        sql = sanitize_sql(arr)
        Array(find_by_sql(sql)).map { |e|e.table_name }
      end

      def self.find_detail_references(table_name)
        arr = connection.find_detail_references_sql_array(table_name)
        sql = sanitize_sql([sql, table_name.upcase])
        find_by_sql(sql)
      end

      def find_each_by_sql(sql, &block)
        connection.select_each(sanitize_sql(sql), "#{name} Load") { |record| yield instantiate(record) }
      end

      def extract_options_from_args!(args) #:nodoc:
        args.last.is_a?(Hash) ? args.pop : {}
      end

      def find_each(*args)
        options =  extract_options_from_args!(args)
        validate_find_options(options)
        set_readonly_option!(options)
        # records = scoped?(:find, :include) || options[:include] ?
        #       # find_with_associations(options) :
        if block_given?
          if scoped?(:find, :include) || options[:include] then
            find_each_with_associations(options) { |r| yield r if r }
          else
            find_each_by_sql(construct_finder_sql(options)) { |r| yield r if r }
          end
        end
      end

      def build_delete_by_primary_key_sql
        keys = primary_key_columns

        index = 1
        "DELETE FROM #{table_name} " \
        'WHERE ' +         "#{keys.map { |c| string = "#{c.name} = :#{index}"; index += 1; string }.join(' AND ') } "
      end

      def build_optimistic_delete_sql
        index = 1
        "DELETE FROM #{table_name} " \
        'WHERE ' +         "#{columns.map { |c| string = build_optimistic_where_element(index, c); index += 1; index += 1 if c.null; string }.join(' AND ') } " +
        "AND ROWID = :#{index}"
      end

      def build_optimistic_update_sql
        index = 1
        "UPDATE #{table_name} " \
        'SET ' +
        "#{columns.map { |c| string = c.name + " = :#{index}"; index += 1; string }.join(', ') } " +
        'WHERE ' +
        "#{columns.map { |c| string = build_optimistic_where_element(index, c); index += 1; index += 1 if c.null; string }.join(' AND ') } "# +
        #"AND ROWID = :#{index}"
      end

      def build_update_by_primary_key_sql
        keys = primary_key_columns

        index = 1
        "UPDATE #{table_name} " \
        'SET ' +
        "#{columns.map { |c| string = c.name + " = :#{index}"; index += 1; string }.join(', ') } " +
        'WHERE ' +
        "#{keys.map { |c| string = "#{c.name} = :#{index}"; index += 1; string }.join(' AND ') } "
      end

      private

      def primary_key_columns
        @primary_key_columns ||= primary_key_as_array.map { |c| columns_hash[c.to_s] }
      end

      def primary_key_as_array
        primary_key.is_a?(Array) ? primary_key : [primary_key]
      end

      def build_optimistic_where_element(index, column)
        sql = '( '        
        # AK: remove timezone information. ruby appends the summer/winter timezone releated to the date and send this as timestamp to oracle
        #    and a timestamp with timezone is not equals the date in the row
        if column.type == :datetime
          sql += "#{column.name} = cast( :#{index} as date ) "
        else
          sql += "#{column.name} = :#{index} "
        end

        index += 1
        if column.null
          sql += "OR ( #{column.name} IS NULL AND :#{index} IS NULL ) "
          index += 1
        end

        sql += ') '
      end

    end

    # Checks if a active record object was changed and if schedule if for DB merge
    #
    # =====Parameters
    # * *-*
    # =====Return value
    # * *self*
    def schedule_merge_on_change
      if orginal_selected_record.nil?
        schedule_merge
        return self
      end

      attributes.each_pair do |key, value|
        if value != orginal_selected_record[key]
          schedule_merge
          return self
        end
      end

      self
    end

    def schedule_merge
      set_id_from_sequence
      ActiveRecord::Bulkoperation::Util::FlushDirtyObjects.get.add_merge(self)
      self
    end

    def schedule_delete
      ActiveRecord::Bulkoperation::Util::FlushDirtyObjects.get.add_delete(self)
      self
    end

    def set_id_from_sequence
      self['id'] = self.class.next_sequence_value if self['id'].nil? && self.class.has_id_column?
    end

    def optimistic_update
      fail NoPersistentRecord.new if  @new_record
      fail NoOrginalRecordFound.new unless orginal_selected_record

      sql = self.class.build_optimistic_update_sql

      types  = []

      for c in self.class.columns
        type = self.class.to_type_symbol(c)
        types << type
      end

      for c in self.class.columns
        type = self.class.to_type_symbol(c)
        types << type
        types << type if c.null
      end

      types << :string

      binds = self.class.columns.map { |c| read_attribute(c.name) }

      get_optimistic_where_binds.each { |v| binds << v }

      self.class.execute_batch_update(sql, types, [binds])
    end

    def optimistic_delete
      fail NoPersistentRecord.new if  @new_record
      fail NoOrginalRecordFound.new unless orginal_selected_record

      sql = self.class.build_optimistic_delete_sql

      binds = get_optimistic_where_binds

      types  = []

      for c in self.class.columns
        type = self.class.to_type_symbol(c)
        types << type
        types << type if c.null
      end

      types << :string

      self.class.execute_batch_update(sql, types, [binds])
      end

    private

    def get_optimistic_where_binds
      binds = []
      self.class.columns.map do |c|
        v = orginal_selected_record[ c.name]
        binds << v
        binds << v if c.null
      end

      binds << orginal_selected_record[ 'rowid']
      binds
    end

    def rowid=(id)
      self['rowid'] = id
    end
    alias_method :row_id=, :rowid=

    def rowid
      self['rowid']
    end
    alias_method :row_id, :rowid
  end
end