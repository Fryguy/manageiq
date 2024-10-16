class MiqReport < ActiveRecord::Base
  include ActiveRecord::AttributeAccessorThatYamls

  include_concern 'Formatting'
  include_concern 'Formatters'
  include_concern 'Seeding'
  include_concern 'ImportExport'
  include_concern 'Generator'
  include_concern 'Notification'
  include_concern 'Schedule'
  include_concern 'Search'
  include YAMLImportExportMixin

  default_scope { where self.conditions_for_my_region_default_scope }

  serialize :cols
  serialize :conditions
  serialize :where_clause
  serialize :include
  serialize :col_order
  serialize :headers
  serialize :order
  serialize :sortby
  serialize :categories
  serialize :timeline
  serialize :graph
  serialize :db_options
  serialize :generate_cols
  serialize :generate_rows
  serialize :col_formats
  serialize :col_options
  serialize :rpt_options
  serialize :display_filter

  validates_presence_of     :name, :title, :db, :rpt_group
  validates_uniqueness_of   :name
  validates_inclusion_of    :rpt_type, :in => %w{ Default Custom }

  has_many                  :miq_report_results, :dependent => :destroy
  belongs_to                :time_profile
  belongs_to                :miq_group
  belongs_to                :user

  attr_accessor_that_yamls :table, :sub_table, :filter_summary, :extras, :ids, :scoped_association, :html_title, :file_name,
                :extras, :record_id, :tl_times, :user_categories, :trend_data, :performance, :include_for_find,
                :report_run_time, :chart

  attr_accessor_that_yamls :reserved # For legacy imports

  GROUPINGS = [[:min, "Minimum"], [:avg, "Average"], [:max, "Maximum"], [:total, "Total"]]
  PIVOTS    = [[:min, "Minimum"], [:avg, "Average"], [:max, "Maximum"], [:total, "Total"]]

  # Scope on reports that have report results.
  #
  # Valid options are:
  #   ::miq_group:    An MiqGroup instance on which to filter
  #   ::miq_group_id: An MiqGroup id on which to filter
  #   ::select:       An Array of MiqReport columns to fetch
  def self.having_report_results(options = {})
    q = self.joins(:miq_report_results).order(arel_table[:id])

    miq_group = MiqGroup.extract_ids(options[:miq_group] || options[:miq_group_id])
    q = q.where(MiqReportResult.arel_table[:miq_group_id].eq(miq_group)) unless miq_group.nil?

    if options[:select]
      cols = options[:select].to_miq_a
      cols = cols.dup.unshift(:id) unless cols.include?(:id)
      cols.each { |c| q = q.select(arel_table[c]) }
    end

    q
  end

  def view_filter_columns
    self.col_order.collect { |c| [self.headers[col_order.index(c)], c] }
  end

  def self.reportable_models
    MiqExpression.base_tables
  end

  def self.get_expressions_by_model(db)
    reports = where(:db => db.to_s, :template_type => "report")
              .where.not(:conditions => nil)
              .select(:id, :name, :conditions)
              .to_a

    # We have to redo the filtering on ruby side because nil conditions
    # can be serialized as non-NULL value in the database.
    reports = reports.select(&:conditions)

    reports.each_with_object({}) { |report, hash| hash[report.name] = report.id }
  end

  def self.get_col_type(path)
    MiqExpression.get_col_type(path)
  end

  def self.get_col_info(path)
    data_type = self.get_col_type(path)
    {
      :data_type         => data_type,
      :available_formats => self.get_available_formats(path, data_type),
      :default_format    => self.get_default_format(path, data_type),
      :numeric           => [:integer, :decimal, :fixnum, :float].include?(data_type)
    }
  end

  def self.display_filter_details(cols, mode)
    # mode => :field || :tag
    # Only return cols from has_many sub-tables
    return [] if cols.nil?
    cols.inject([]) do |r,c|
      # eg. c = ["Host.Hardware.Disks : File Name", "Host.hardware.disks-filename"]
      parts = c.last.split(".")
      parts[-1] = parts.last.split("-").first # Strip off field name from last element

      if parts.last == "managed"
        next(r) unless mode == :tag
        parts.pop # Remove "managed" from tail andjust just evaluate relationship
      else
        next(r) unless mode == :field
      end

      model = parts.shift
      relats = MiqExpression.get_relats(model)
      # Build relats hash fetch path like: [:reflections, :hardware, :reflections, :disks, :parent, :multivalue]
      path = parts.inject([]) {|a,p| a << :reflections; a << p.to_sym}
      path += [:parent, :multivalue]
      multi = relats.fetch_path(*path)
      multi == true ? r << c : r
    end

  end

  def db_class
    self.db.is_a?(Class) ? self.db : Object.const_get(self.db)
  end

  def contains_records?
    (extras.key?(:total_html_rows) && extras[:total_html_rows] > 0) ||
      (table && table.data.length > 0)
  end

  def to_hash
    keys = self.class.attr_accessor_that_yamls
    keys.each_with_object(attributes.to_hash) { |k, h| h[k] = send(k) }
  end

  def self.from_hash(h)
    new(h)
  end
end
