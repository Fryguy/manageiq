$LOAD_PATH << File.join(GEMS_PENDING_ROOT, "util/xml")
$LOAD_PATH << File.join(GEMS_PENDING_ROOT, "util/win32")
$LOAD_PATH << File.join(GEMS_PENDING_ROOT, "metadata/linux")

require 'ostruct'
require 'MiqSockUtil'
require 'xml_utils'
require 'cgi'               # Used for URL encoding/decoding
require 'LinuxUsers'
require 'LinuxUtils'

$LOAD_PATH << File.join(GEMS_PENDING_ROOT, "metadata/ScanProfile")
require 'HostScanProfiles'

class Host < ActiveRecord::Base
  include NewWithTypeStiMixin

  VENDOR_TYPES = {
    # DB            Displayed
    "microsoft"       => "Microsoft",
    "redhat"          => "RedHat",
    "vmware"          => "VMware",
    "openstack_infra" => "OpenStack Infrastructure",
    "unknown"         => "Unknown",
    nil               => "Unknown",
  }

  HOST_DISCOVERY_TYPES = {
    'vmware' => 'esx',
    'ipmi'   => 'ipmi'
  }

  HOST_CREATE_OS_TYPES = {
    'VMware ESX' => 'linux_generic',
    # 'Microsoft Hyper-V' => 'windows_generic'
  }

  validates_presence_of     :name
  validates_uniqueness_of   :name
  validates_inclusion_of    :user_assigned_os, :in => ["linux_generic", "windows_generic", nil]
  validates_inclusion_of    :vmm_vendor, :in => VENDOR_TYPES.values

  belongs_to                :ext_management_system, :foreign_key => "ems_id"
  belongs_to                :ems_cluster
  has_one                   :operating_system, :dependent => :destroy
  has_one                   :hardware, :dependent => :destroy
  has_many                  :vms_and_templates, :dependent => :nullify
  has_many                  :vms
  has_many                  :miq_templates
  has_and_belongs_to_many   :storages
  has_many                  :switches, :dependent => :destroy
  has_many                  :patches, :dependent => :destroy
  has_many                  :system_services, :dependent => :destroy
  has_many                  :host_services, :class_name => "SystemService", :foreign_key => "host_id"

  has_many                  :metrics,        :as => :resource  # Destroy will be handled by purger
  has_many                  :metric_rollups, :as => :resource  # Destroy will be handled by purger
  has_many                  :vim_performance_states, :as => :resource  # Destroy will be handled by purger

  has_many                  :ems_events, -> { where("host_id = ? OR dest_host_id = ?", id, id).order(:timestamp) }, :class_name => "EmsEvent"
  has_many                  :ems_events_src, :class_name => "EmsEvent"
  has_many                  :ems_events_dest, :class_name => "EmsEvent", :foreign_key => :dest_host_id

  has_many                  :policy_events, -> { order("timestamp") }
  has_many                  :guest_applications, :dependent => :destroy

  has_many                  :filesystems, :as => :resource, :dependent => :destroy
  has_many                  :directories, -> { where("rsc_type = 'dir'") }, :as => :resource, :class_name => "Filesystem"
  has_many                  :files,       -> { where("rsc_type = 'file'") }, :as => :resource, :class_name => "Filesystem"

  # Accounts - Users and Groups
  has_many                  :accounts, :dependent => :destroy
  has_many                  :users, -> { where("accttype = 'user'") }, :class_name => "Account", :foreign_key => "host_id"
  has_many                  :groups, -> { where("accttype = 'group'") }, :class_name => "Account", :foreign_key => "host_id"

  has_many                  :advanced_settings, :as => :resource, :dependent => :destroy

  has_many                  :miq_alert_statuses, :dependent => :destroy, :as => :resource

  has_one                   :miq_cim_instance, :as => :vmdb_obj, :dependent => :destroy

  has_many                  :host_service_groups, :dependent => :destroy

  serialize                 :settings

  # TODO: Remove all callers of address
  alias_attribute :address, :hostname

  def settings
    super || self.settings = VMDB::Config.new("hostdefaults").get(:host)
  end

  include SerializedEmsRefObjMixin
  include ProviderObjectMixin

  include WebServiceAttributeMixin
  include EventMixin

  include CustomAttributeMixin
  has_many :ems_custom_attributes, -> { where("source = 'VC'") }, :as => :resource, :dependent => :destroy, :class_name => "CustomAttribute"

  acts_as_miq_taggable
  include ReportableMixin

  virtual_column :os_image_name,                :type => :string,      :uses => [:operating_system, :hardware]
  virtual_column :platform,                     :type => :string,      :uses => [:operating_system, :hardware]
  virtual_column :v_owning_cluster,             :type => :string,      :uses => :ems_cluster
  virtual_column :v_owning_datacenter,          :type => :string,      :uses => :all_relationships
  virtual_column :v_owning_folder,              :type => :string,      :uses => :all_relationships
  virtual_column :v_total_storages,             :type => :integer,     :uses => :storages
  virtual_column :v_total_vms,                  :type => :integer,     :uses => :vms
  virtual_column :v_total_miq_templates,        :type => :integer,     :uses => :miq_templates
  virtual_column :total_vcpus,                  :type => :integer,     :uses => :logical_cpus
  virtual_column :num_cpu,                      :type => :integer,     :uses => :hardware
  virtual_column :logical_cpus,                 :type => :integer,     :uses => :hardware
  virtual_column :cores_per_socket,             :type => :integer,     :uses => :hardware
  virtual_column :ram_size,                     :type => :integer
  virtual_column :enabled_inbound_ports,        :type => :numeric_set  # The following are not set to use anything
  virtual_column :enabled_outbound_ports,       :type => :numeric_set  # because get_ports ends up re-querying the
  virtual_column :enabled_udp_inbound_ports,    :type => :numeric_set  # database anyway.
  virtual_column :enabled_udp_outbound_ports,   :type => :numeric_set
  virtual_column :enabled_tcp_inbound_ports,    :type => :numeric_set
  virtual_column :enabled_tcp_outbound_ports,   :type => :numeric_set
  virtual_column :all_enabled_ports,            :type => :numeric_set
  virtual_column :service_names,                :type => :string_set,  :uses => :system_services
  virtual_column :enabled_run_level_0_services, :type => :string_set,  :uses => :host_services
  virtual_column :enabled_run_level_1_services, :type => :string_set,  :uses => :host_services
  virtual_column :enabled_run_level_2_services, :type => :string_set,  :uses => :host_services
  virtual_column :enabled_run_level_3_services, :type => :string_set,  :uses => :host_services
  virtual_column :enabled_run_level_4_services, :type => :string_set,  :uses => :host_services
  virtual_column :enabled_run_level_5_services, :type => :string_set,  :uses => :host_services
  virtual_column :enabled_run_level_6_services, :type => :string_set,  :uses => :host_services
  virtual_column :last_scan_on,                 :type => :time,        :uses => :last_drift_state_timestamp
  virtual_column :v_annotation,                 :type => :string,      :uses => :hardware
  virtual_column :ipmi_enabled,                 :type => :boolean

  virtual_has_many   :resource_pools,                               :uses => :all_relationships
  virtual_has_many   :lans,                                         :uses => {:switches => :lans}
  virtual_has_many   :miq_scsi_luns,                                :uses => {:hardware => {:storage_adapters => {:miq_scsi_targets => :miq_scsi_luns}}}
  virtual_has_many   :processes,       :class_name => "OsProcess",  :uses => {:operating_system => :processes}
  virtual_has_many   :event_logs,                                   :uses => {:operating_system => :event_logs}
  virtual_has_many   :firewall_rules,                               :uses => {:operating_system => :firewall_rules}

  virtual_has_many  :base_storage_extents, :class_name => "CimStorageExtent"
  virtual_has_many  :storage_systems,      :class_name => "CimComputerSystem"
  virtual_has_many  :file_shares,          :class_name => 'SniaFileShare'
  virtual_has_many  :storage_volumes,      :class_name => 'CimStorageVolume'
  virtual_has_many  :logical_disks,        :class_name => 'CimLogicalDisk'

  alias datastores storages    # Used by web-services to return datastores as the property name

  alias parent_cluster ems_cluster
  alias owning_cluster ems_cluster

  include RelationshipMixin
  self.default_relationship_type = "ems_metadata"

  include DriftStateMixin
  alias last_scan_on last_drift_state_timestamp

  include UuidMixin
  include MiqPolicyMixin
  include AlertMixin
  include Metric::CiMixin
  include FilterableMixin
  include AuthenticationMixin
  include AsyncDeleteMixin
  include ComplianceMixin
  include VimConnectMixin

  before_create :make_smart
  after_save    :process_events

  def authentication_check_role
    'smartstate'
  end

  def to_s
    name
  end

  def v_annotation
    hardware.try(:annotation)
  end

  # host settings
  def autoscan
    settings[:autoscan]
  end

  def autoscan=(switch)
    settings[:autoscan] = switch
  end

  def inherit_mgt_tags
    settings[:inherit_mgt_tags]
  end

  def inherit_mgt_tags=(switch)
    settings[:inherit_mgt_tags] = switch
  end

  def scan_frequency
    settings[:scan_frequency]
  end

  def scan_frequency=(switch)
    settings[:scan_frequency] = switch
  end
  # end host settings

  def my_zone
    ems = ext_management_system
    ems ? ems.my_zone : MiqServer.my_zone
  end

  def make_smart
    self.smart = true
  end

  def process_events
    return unless ems_cluster_id_changed?

    raise_cluster_event(ems_cluster_id_was, "host_remove_from_cluster") if ems_cluster_id_was
    raise_cluster_event(ems_cluster, "host_add_to_cluster") if ems_cluster_id
  end # after_save

  def raise_cluster_event(ems_cluster, event)
    # accept ids or objects
    ems_cluster = EmsCluster.find(ems_cluster) unless ems_cluster.kind_of? EmsCluster
    inputs = {:ems_cluster => ems_cluster, :host => self}
    begin
      MiqEvent.raise_evm_event(self, event, inputs)
      _log.info("Raised EVM Event: [#{event}, host: #{name}(#{id}), cluster: #{ems_cluster.name}(#{ems_cluster.id})]")
    rescue => err
      _log.warn("Error raising EVM Event: [#{event}, host: #{name}(#{id}), cluster: #{ems_cluster.name}(#{ems_cluster.id})], '#{err.message}'")
    end
  end
  private :raise_cluster_event

  # is_available?
  # Returns:  true or false
  #
  # The UI calls this method to determine if a feature is supported for this Host
  # and determines if a button should be displayed.  This method should return true
  # even if a function is not 'currently' available due to some condition that is not
  # being met.
  def is_available?(request_type)
    send("validate_#{request_type}")[:available]
  end

  # is_available_now_error_message
  # Returns an error message string if there is an error.
  # Returns nil to indicate no errors.
  # This method is used by the UI along with the is_available? methods.
  def is_available_now_error_message(request_type)
    send("validate_#{request_type}")[:message]
  end

  def raise_is_available_now_error_message(request_type)
    msg = send("validate_#{request_type}")[:message]
    raise MiqException::MiqVmError, msg unless msg.nil?
  end

  def validate_reboot
    validate_esx_host_connected_to_vc_with_power_state('on')
  end

  def validate_shutdown
    validate_esx_host_connected_to_vc_with_power_state('on')
  end

  def validate_standby
    validate_esx_host_connected_to_vc_with_power_state('on')
  end

  def validate_enter_maint_mode
    validate_esx_host_connected_to_vc_with_power_state('on')
  end

  def validate_exit_maint_mode
    validate_esx_host_connected_to_vc_with_power_state('maintenance')
  end

  def validate_enable_vmotion
    validate_esx_host_connected_to_vc_with_power_state('on')
  end

  def validate_disable_vmotion
    validate_esx_host_connected_to_vc_with_power_state('on')
  end

  def validate_vmotion_enabled?
    validate_esx_host_connected_to_vc_with_power_state('on')
  end

  def validate_start
    validate_ipmi('off')
  end

  def validate_stop
    validate_ipmi('on')
  end

  def validate_reset
    validate_ipmi
  end

  def validate_ipmi(pstate = nil)
    return {:available => false, :message => "The Host is not configured for IPMI"}   if ipmi_address.blank?
    return {:available => false, :message => "The Host has no IPMI credentials"}      if authentication_type(:ipmi).nil?
    return {:available => false, :message => "The Host has invalid IPMI credentials"} if authentication_userid(:ipmi).blank? || authentication_password(:ipmi).blank?
    msg = validate_power_state(pstate)
    return msg unless msg.nil?
    {:available => true,  :message => nil }
  end

  def validate_esx_host_connected_to_vc_with_power_state(pstate)
    msg = validate_esx_host_connected_to_vc
    return msg unless msg.nil?
    msg = validate_power_state(pstate)
    return msg unless msg.nil?
    {:available => true,   :message => nil }
  end

  def validate_power_state(pstate)
    return nil if pstate.nil?
    case pstate.class.name
    when 'String'
      return {:available => false,   :message => "The Host is not powered '#{pstate}'"} unless power_state == pstate
    when 'Array'
      return {:available => false,   :message => "The Host is not powered #{pstate.inspect}"} unless pstate.include?(power_state)
    end
  end

  def validate_esx_host_connected_to_vc
    # Check the basic require to interact with a VM.
    return {:available => false, :message => "The Host is not connected to an active #{ui_lookup(:table => "ext_management_systems")}"} unless has_active_ems?
    return {:available => false, :message => "The Host is not VMware ESX"} unless is_vmware_esx?
    nil
  end

  def has_active_ems?
    !!ext_management_system
  end

  def run_ipmi_command(verb)
    require 'miq-ipmi'
    _log.info("Invoking [#{verb}] for Host: [#{name}], IPMI Address: [#{ipmi_address}], IPMI Username: [#{authentication_userid(:ipmi)}]")
    ipmi = MiqIPMI.new(ipmi_address, *auth_user_pwd(:ipmi))
    ipmi.send(verb)
  end

  def policy_prevented?(request)
    MiqEvent.raise_evm_event(self, request, {:host => self})
  rescue MiqException::PolicyPreventAction => err
    _log.info "#{err}"
    true
  else
    false
  end

  def ipmi_power_on
    run_ipmi_command :power_on
  end

  def ipmi_power_off
    run_ipmi_command :power_off
  end

  def ipmi_power_reset
    run_ipmi_command :power_reset
  end

  def reset
    msg = validate_reset
    if msg[:available]
      ipmi_power_reset unless policy_prevented?("request_host_reset")
    else
      _log.warn("Cannot stop because <#{msg[:message]}>")
    end
  end

  def start
    if validate_start[:available] && power_state == 'standby' && respond_to?(:vim_power_up_from_standby)
      vim_power_up_from_standby unless policy_prevented?("request_host_start")
    else
      msg = validate_ipmi
      if msg[:available]
        pstate = run_ipmi_command(:power_state)
        if pstate == 'off'
          ipmi_power_on unless policy_prevented?("request_host_start")
        else
          _log.warn("Non-Startable IPMI power state = <#{pstate.inspect}>")
        end
      else
        _log.warn("Cannot start because <#{msg[:message]}>")
      end
    end
  end

  def stop
    msg = validate_stop
    if msg[:available]
      ipmi_power_off unless policy_prevented?("request_host_stop")
    else
      _log.warn("Cannot stop because <#{msg[:message]}>")
    end
  end

  def standby
    msg = validate_standby
    if msg[:available]
      if power_state == 'on' && respond_to?(:vim_power_down_to_standby)
        vim_power_down_to_standby unless policy_prevented?("request_host_standby")
      else
        _log.warn("Cannot go into standby mode from power state = <#{power_state.inspect}>")
      end
    else
      _log.warn("Cannot go into standby mode because <#{msg[:message]}>")
    end
  end

  def enter_maint_mode
    msg = validate_enter_maint_mode
    if msg[:available]
      if power_state == 'on' && respond_to?(:vim_enter_maintenance_mode)
        vim_enter_maintenance_mode unless policy_prevented?("request_host_enter_maintenance_mode")
      else
        _log.warn("Cannot enter maintenance mode from power state = <#{power_state.inspect}>")
      end
    else
      _log.warn("Cannot enter maintenance mode because <#{msg[:message]}>")
    end
  end

  def exit_maint_mode
    msg = validate_enter_maint_mode
    if msg[:available] && respond_to?(:vim_exit_maintenance_mode)
      vim_exit_maintenance_mode unless policy_prevented?("request_host_exit_maintenance_mode")
    else
      _log.warn("Cannot exit maintenance mode because <#{msg[:message]}>")
    end
  end

  def shutdown
    msg = validate_shutdown
    if msg[:available] && respond_to?(:vim_shutdown)
      vim_shutdown unless policy_prevented?("request_host_shutdown")
    else
      _log.warn("Cannot shutdown because <#{msg[:message]}>")
    end
  end

  def reboot
    msg = validate_reboot
    if msg[:available] && respond_to?(:vim_reboot)
      vim_reboot unless policy_prevented?("request_host_reboot")
    else
      _log.warn("Cannot reboot because <#{msg[:message]}>")
    end
  end

  def enable_vmotion
    msg = validate_enable_vmotion
    if msg[:available] && respond_to?(:vim_enable_vmotion)
      vim_enable_vmotion unless policy_prevented?("request_host_enable_vmotion")
    else
      _log.warn("Cannot enable vmotion because <#{msg[:message]}>")
    end
  end

  def disable_vmotion
    msg = validate_disable_vmotion
    if msg[:available] && respond_to?(:vim_disable_vmotion)
      vim_disable_vmotion unless policy_prevented?("request_host_disable_vmotion")
    else
      _log.warn("Cannot disable vmotion because <#{msg[:message]}>")
    end
  end

  def vmotion_enabled?
    msg = validate_vmotion_enabled?
    if msg[:available] && respond_to?(:vim_vmotion_enabled?)
      vim_vmotion_enabled? unless policy_prevented?("request_host_vmotion_enabled")
    else
      _log.warn("Cannot check if vmotion is enabled because <#{msg[:message]}>")
    end
  end

  def resolve_hostname!
    addr = MiqSockUtil.resolve_hostname(hostname)
    update_attributes!(:ipaddress => addr) unless addr.nil?
  end

  # Scan for VMs in a path defined in a repository
  def add_elements(data)
    if data.kind_of?(Hash) && data[:type] == :ems_events
      _log.info("Adding HASH elements for Host id:[#{id}]-[#{name}] from [#{data[:type]}]")
      add_ems_events(data)
    end
  rescue => err
    _log.log_backtrace(err)
  end

  def ipaddresses
    hardware.nil? ? [] : hardware.ipaddresses
  end

  def hostnames
    hardware.nil? ? [] : hardware.hostnames
  end

  def mac_addresses
    hardware.nil? ? [] : hardware.mac_addresses
  end

  def has_config_data?
    !operating_system.nil? && !hardware.nil?
  end

  def os_image_name
    OperatingSystem.image_name(self)
  end

  def platform
    OperatingSystem.platform(self)
  end

  def product_name
    operating_system.nil? ? "" : operating_system.product_name
  end

  def service_pack
    operating_system.nil? ? "" : operating_system.service_pack
  end

  def arch
    if vmm_product.to_s.include?('ESX')
      return 'x86_64' if vmm_version.to_i >= 4
      return 'x86'
    end

    return "unknown" unless hardware && !hardware.cpu_type.nil?
    cpu = hardware.cpu_type.to_s.downcase
    return cpu if cpu.include?('x86')
    return "x86" if cpu.starts_with? "intel"
    "unknown"
  end

  def platform_arch
    ret = [os_image_name.split("_")[0], arch == "unknown" ? "x86" : arch]
    ret.include?("unknown") ? nil : ret
  end

  def acts_as_ems?
    product = vmm_product.to_s.downcase
    ['hyperv', 'hyper-v'].any? { |p| product.include?(p) }
  end

  def refreshable_status
    if ext_management_system
      return {:show => true, :enabled => true, :message => ""}
    end

    {:show => false, :enabled => false, :message => "Host not configured for refresh"}
  end

  def scannable_status
    s = refreshable_status
    return s if s[:show] || s[:enabled]

    s[:show] = true
    if has_credentials?(:ipmi) && ipmi_address.present?
      s.merge!(:enabled => true, :message => "")
    elsif ipmi_address.blank?
      s.merge!(:enabled => false, :message => "Provide an IPMI Address")
    elsif missing_credentials?(:ipmi)
      s.merge!(:enabled => false, :message => "Provide credentials for IPMI")
    end

    s
  end

  def is_refreshable?
    refreshable_status[:show]
  end

  def is_refreshable_now?
    refreshable_status[:enabled]
  end

  def is_refreshable_now_error_message
    refreshable_status[:message]
  end

  def self.refresh_ems(host_ids)
    host_ids = [host_ids] unless host_ids.kind_of?(Array)
    host_ids = host_ids.collect { |id| [Host, id] }
    EmsRefresh.queue_refresh(host_ids)
  end

  def refresh_ems
    raise "No #{ui_lookup(:table => "ext_management_systems")} defined" unless ext_management_system
    raise "No #{ui_lookup(:table => "ext_management_systems")} credentials defined" unless ext_management_system.has_credentials?
    raise "#{ui_lookup(:table => "ext_management_systems")} failed last authentication check" unless ext_management_system.authentication_status_ok?
    EmsRefresh.queue_refresh(self)
  end

  def is_scannable?
    scannable_status[:show]
  end

  def is_scannable_now?
    scannable_status[:enabled]
  end

  def is_scannable_now_error_message
    scannable_status[:message]
  end

  def is_vmware?
    vmm_vendor.to_s.strip.downcase == 'vmware'
  end

  def is_vmware_esx?
    is_vmware? && vmm_product.to_s.strip.downcase.starts_with?('esx')
  end

  def is_vmware_esxi?
    product = vmm_product.to_s.strip.downcase
    is_vmware? && product.starts_with?('esx') && product.ends_with?('i')
  end

  def state
    power_state
  end

  def state=(new_state)
    return if power_state == new_state

    # state_changed_on = Time.now.utc
    # previous_state = power_state
    self.power_state = new_state
  end

  def self.lookUpHost(hostname, ipaddr)
    h   = Host.where("lower(hostname) = ?", hostname.downcase).where(:ipaddress => ipaddr).first if hostname && ipaddr
    h ||= Host.where("lower(hostname) = ?", hostname.downcase).first                             if hostname
    h ||= Host.where(:ipaddress => ipaddr).first                                                 if ipaddr
    h ||= Host.where("lower(hostname) LIKE ?", "#{hostname.downcase}.%").first                   if hostname
    h
  end

  def vmm_vendor
    VENDOR_TYPES[read_attribute(:vmm_vendor)]
  end

  def vmm_vendor=(v)
    v = VENDOR_TYPES.key(v) if      VENDOR_TYPES.value?(v)
    v = nil                 unless  VENDOR_TYPES.key?(v)

    self[:vmm_vendor] = v
  end

  #
  # Relationship methods
  #

  def disconnect_inv
    disconnect_ems
    remove_all_parents(:of_type => ['EmsFolder', 'EmsCluster'])
  end

  def connect_ems(e)
    return if ext_management_system == e

    _log.debug "Connecting Host [#{name}] id [#{id}] to EMS [#{e.name}] id [#{e.id}]"
    self.ext_management_system = e
    save
  end

  def disconnect_ems(e=nil)
    if e.nil? || self.ext_management_system == e
      log_text = " from EMS [#{ext_management_system.name}] id [#{ext_management_system.id}]" unless ext_management_system.nil?
      _log.info "Disconnecting Host [#{name}] id [#{id}]#{log_text}"

      self.ext_management_system = nil
      self.state = "unknown"
      save
    end
  end

  def connect_storage(s)
    unless storages.include?(s)
      _log.debug "Connecting Host [#{name}] id [#{id}] to Storage [#{s.name}] id [#{s.id}]"
      storages << s
      save
    end
  end

  def disconnect_storage(s)
    _log.info "Disconnecting Host [#{name}] id [#{id}] from Storage [#{s.name}] id [#{s.id}]"
    storages.delete(s)
    save
  end

  # Vm relationship methods
  def direct_vms
    # Look for only the Vms at the second depth (default RP + 1)
    rels = descendant_rels(:of_type => 'Vm').select { |r| (r.depth - depth) == 2 }
    Relationship.resources(rels).sort_by { |r| r.name.downcase }
  end

  # Resource Pool relationship methods
  def default_resource_pool
    Relationship.resource(child_rels(:of_type => 'ResourcePool').first)
  end

  def resource_pools
    # Look for only the resource_pools at the second depth (default depth + 1)
    rels = descendant_rels(:of_type => 'ResourcePool')
    min_depth = rels.collect(&:depth).min
    rels = rels.select { |r| r.depth == min_depth + 1 }
    Relationship.resources(rels).sort_by { |r| r.name.downcase }
  end

  def resource_pools_with_default
    # Look for only the resource_pools up to the second depth (default depth + 1)
    rels = descendant_rels(:of_type => 'ResourcePool')
    min_depth = rels.collect(&:depth).min
    rels = rels.select { |r| r.depth <= min_depth + 1 }
    Relationship.resources(rels).sort_by { |r| r.name.downcase }
  end

  # All RPs under this Host and all child RPs
  def all_resource_pools
    descendants(:of_type => 'ResourcePool')[1..-1].sort_by { |r| r.name.downcase }
  end

  def all_resource_pools_with_default
    descendants(:of_type => 'ResourcePool').sort_by { |r| r.name.downcase }
  end

  # Parent relationship methods
  def parent_folder
    p = parent
    p.kind_of?(EmsFolder) ? p : nil
  end

  def owning_folder
    detect_ancestor(:of_type => "EmsFolder") { |a| !a.is_datacenter && !["host", "vm"].include?(a.name) }
  end

  def parent_datacenter
    detect_ancestor(:of_type => "EmsFolder") { |a| a.is_datacenter }
  end
  alias owning_datacenter parent_datacenter

  def lans
    all_lans = []
    switches.each { |s| all_lans += s.lans unless s.lans.nil? } unless switches.nil?
    all_lans
  end

  def self.save_metadata(id, dataArray)
    begin
      _log.info "for host [#{id}]"
      host = Host.find_by_id(id)
      data, data_type = dataArray
      if data_type.include?('yaml')
        data.replace(MIQEncode.decode(data)) if data_type.include?('b64,zlib')
        doc = YAML.load(data)
      else
        data.replace(MIQEncode.decode(data)) if data_type.include?('b64,zlib')
        doc = MiqXml.load(data)
      end
      host.add_elements(doc)
      host.save!
      _log.info "for host [#{id}] host saved"
    rescue => err
      _log.log_backtrace(err)
      return false
    end
  end

  def self.rss_settings_changes(name, options)
    find_by_audit_for_rss("agent_settings_change", options)
  end

  def self.rss_version_changes(name, options)
    find_by_audit_for_rss("agent_version_activate", options)
  end


  def self.find_by_audit_for_rss(event_name, options = {})
    result = []
    AuditEvent.where(:target_class => 'Host', :event => event_name).
               order(options[:orderby]).
               limit(options[:limit_to_count]).
               each do |event|
      if options[:tags] && options[:tags_include]
        any_or_all = options[:tags_include].to_sym
        host = Host.find_tagged_with(
                      any_or_all => options[:tags],
                      :ns        => options[:tag_ns]
                    ).where(:id => event.target_id).first
      else
        host = Host.find(event.target_id)
      end
      result.push(OpenStruct.new(host.attributes.merge(event.attributes))) unless host.nil?
    end
    result
  end

  def self.multi_host_update(host_ids, attr_hash = {}, creds = {})
    errors = []
    return true if host_ids.blank?
    host_ids.each do |id|
      begin
        host = Host.find(id)
        host.update_authentication(creds)
        host.update_attributes!(attr_hash)
      rescue ActiveRecord::RecordNotFound => err
        _log.warn("#{err.class.name}-#{err}")
        next
      rescue => err
        errors << err.to_s
        _log.error("#{err.class.name}-#{err}")
        next
      end
    end
    return errors.empty? ? true : errors
  end

  def verify_credentials(auth_type=nil, options={})
    raise MiqException::MiqHostError, "No credentials defined" if self.missing_credentials?(auth_type)
    raise MiqException::MiqHostError, "Logon to platform [#{self.os_image_name}] not supported" if auth_type.to_s != 'ipmi' && self.os_image_name !~ /linux_*/

    case auth_type.to_s
    when 'remote' then verify_credentials_with_ssh(auth_type, options)
    when 'ws'     then verify_credentials_with_ws(auth_type)
    when 'ipmi'   then verify_credentials_with_ipmi(auth_type)
    else
      verify_credentials_with_ws(auth_type)
    end

    true
  end

  def verify_credentials_with_ws(_auth_type = nil, _options = {})
    raise NotImplementedError, "#{__method__} not implemented in #{self.class.name}"
  end

  def verify_credentials_with_ssh(auth_type=nil, options={})
    raise MiqException::MiqHostError, "No credentials defined" if self.missing_credentials?(auth_type)
    raise MiqException::MiqHostError, "Logon to platform [#{self.os_image_name}] not supported" unless self.os_image_name =~ /linux_*/

    begin
      # connect_ssh logs address and user name(s) being used to make connection
      _log.info "Verifying Host SSH credentials for [#{name}]"
      connect_ssh(options) {|ssu| ssu.exec("uname -a")}
    rescue Net::SSH::AuthenticationFailed
      raise MiqException::MiqInvalidCredentialsError, "Login failed due to a bad username or password."
    rescue Net::SSH::HostKeyMismatch
      raise # Re-raise the error so the UI can prompt the user to allow the keys to be reset.
    rescue Exception => err
      _log.warn("#{err.inspect}")
      raise MiqException::MiqHostError, "Unexpected response returned from system, see log for details"
    else
      true
    end
  end

  def verify_credentials_with_ipmi(auth_type=nil)
    raise "No credentials defined for IPMI" if missing_credentials?(auth_type)

    require 'miq-ipmi'
    address = ipmi_address
    raise MiqException::MiqHostError, "IPMI address is not configured for this Host" if address.blank?

    if MiqIPMI.is_available?(address)
      ipmi = MiqIPMI.new(address, *auth_user_pwd(auth_type))
      raise MiqException::MiqInvalidCredentialsError, "Login failed due to a bad username or password." unless ipmi.connected?
    else
      raise MiqException::MiqHostError, "IPMI is not available on this Host"
    end
  end

  def self.discoverByIpRange(starting, ending, options={:ping => true})
    options[:timeout] ||= 10
    pattern = %r{^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$}
    raise "Starting address is malformed" if (starting =~ pattern).nil?
    raise "Ending address is malformed" if (ending =~ pattern).nil?

    starting.split(".").each_index {|i|
      raise "IP address octets must be 0 to 255" if starting.split(".")[i].to_i > 255 || ending.split(".")[i].to_i > 255
      raise "Ending address must be greater than starting address" if starting.split(".")[i].to_i > ending.split(".")[i].to_i
    }

    network_id = starting.split(".")[0..2].join(".")
    host_start = starting.split(".").last.to_i
    host_end = ending.split(".").last.to_i

    host_start.upto(host_end) {|h|
      ipaddr = network_id + "." + h.to_s

      unless Host.find_by_ipaddress(ipaddr).nil? # skip discover for existing hosts
        _log.info "ipaddress '#{ipaddr}' exists, skipping discovery"
        next
      end

      discover_options = {:ipaddr         => ipaddr,
                          :usePing        => options[:ping],
                          :timeout        => options[:timeout],
                          :discover_types => options[:discover_types],
                          :credentials    => options[:credentials]
      }

      # Add Windows domain credentials for HyperV WMI checks
      default_zone = Zone.find_by_name('default')
      if !default_zone.nil? && default_zone.has_authentication_type?(:windows_domain)
        discover_options[:windows_domain] = [default_zone.authentication_userid(:windows_domain), default_zone.authentication_password_encrypted(:windows_domain)]
      end

      MiqQueue.put(:class_name => "Host", :method_name => "discoverHost", :data => Marshal.dump(discover_options), :server_guid => MiqServer.my_guid)
    }
  end

  def reset_discoverable_fields
    raise "Host Not Resettable - No IPMI Address" if ipmi_address.blank?
    cred = self.authentication_type(:ipmi)
    raise "Host Not Resettable - No IPMI Credentials" if cred.nil?

    run_callbacks(:destroy) { false } # Run only the before_destroy callbacks to destroy all associations
    reload

    attributes.each do |key, value|
      next if %w{id guid ipmi_address mac_address name created_on updated_on vmm_vendor}.include?(key)
      send("#{key}=", nil)
    end

    make_smart # before_create callback
    self.settings   = VMDB::Config.new("hostdefaults").get(:host)
    self.name       = "IPMI <#{ipmi_address}>"
    self.vmm_vendor = 'unknown'
    save!

    authentications.create(cred.attributes) unless cred.nil?
    self
  end

  def detect_discovered_os(ost)
    # Determine os
    os_type = nil
    if vmm_vendor == "vmware"
      os_name = "VMware ESX Server"
    elsif ost.os.include?(:linux)
      os_name = "linux"
    elsif ost.os.include?(:mswin)
      os_name = "windows"
      os_type = os_name
    else
      os_name = nil
    end

    return os_name, os_type
  end

  def detect_discovered_hypervisor(ost, ipaddr)
    find_method = :find_by_ipaddress
    if ost.hypervisor.include?(:hyperv)
      self.name        = "Microsoft Hyper-V (#{ipaddr})"
      self.type        = "HostMicrosoft"
      self.ipaddress   = ipaddr
      self.vmm_vendor  = "microsoft"
      self.vmm_product = "Hyper-V"
    elsif ost.hypervisor.include?(:esx)
      self.name        = "VMware ESX Server (#{ipaddr})"
      self.ipaddress   = ipaddr
      self.vmm_vendor  = "vmware"
      self.vmm_product = "Esx"
      if has_credentials?(:ws)
        begin
          with_provider_connection(:ip => ipaddr) do |vim|
            _log.info "VIM Information for ESX Host with IP Address: [#{ipaddr}], Information: #{vim.about.inspect}"
            self.vmm_product     = vim.about['name'].dup.split(' ').last
            self.vmm_version     = vim.about['version']
            self.vmm_buildnumber = vim.about['build']
            self.name            = "#{vim.about['name']} (#{ipaddr})"
          end
        rescue => err
          _log.warn "Cannot connect to ESX Host with IP Address: [#{ipaddr}], Username: [#{authentication_userid(:ws)}] because #{err.message}"
        end
      end
      self.type = %w(esx esxi).include?(vmm_product.to_s.downcase) ? "ManageIQ::Providers::Vmware::InfraManager::HostEsx" : "ManageIQ::Providers::Vmware::InfraManager::Host"
    elsif ost.hypervisor.include?(:ipmi)
      find_method       = :find_by_ipmi_address
      self.name         = "IPMI (#{ipaddr})"
      self.type         = "Host"
      self.vmm_vendor   = "unknown"
      self.vmm_product  = nil
      self.ipmi_address = ipaddr
      self.ipaddress    = nil
      self.hostname     = nil
    else
      self.vmm_vendor   = ost.hypervisor.join(", ")
      self.type         = "Host"
    end

    find_method
  end

  def self.ost_inspect(ost)
    hash = ost.marshal_dump.dup
    hash.delete(:credentials)
    OpenStruct.new(hash).inspect
  end

  def rediscover(ipaddr, discover_types = [:esx])
    require 'discovery/MiqDiscovery'
    ost = OpenStruct.new(:usePing => true, :discover_types => discover_types, :ipaddr => ipaddr)
    _log.info "Rediscovering Host: #{ipaddr} with types: #{discover_types.inspect}"
    begin
      MiqDiscovery.scanHost(ost)
      _log.info "Rediscovering Host: #{ipaddr} raw results: #{self.class.ost_inspect(ost)}"

      unless ost.hypervisor.empty?
        detect_discovered_hypervisor(ost, ipaddr)
        os_name, os_type = detect_discovered_os(ost)
        EmsRefresh.save_operating_system_inventory(self, :product_name => os_name, :product_type => os_type) unless os_name.nil?
        EmsRefresh.save_hardware_inventory(self, :cpu_type => "intel")
        save!
      end
    rescue => err
      _log.log_backtrace(err)
    end
  end

  def self.discoverHost(options)
    require 'discovery/MiqDiscovery'
    ost = OpenStruct.new(Marshal.load(options))
    _log.info "Discovering Host: #{ost_inspect(ost)}"
    begin
      MiqDiscovery.scanHost(ost)

      unless ost.hypervisor.empty?
        _log.info "Discovered: #{ost_inspect(ost)}"

        if [:virtualcenter, :scvmm, :rhevm].any? {|ems_type| ost.hypervisor.include?(ems_type)}
          ExtManagementSystem.create_discovered_ems(ost)
          return # only create ems instance, no host.
        end

        host = new(
          :name      => "#{ost.ipaddr} - discovered #{Time.now.utc.strftime("%Y-%m-%d %H:%M %Z")}",
          :ipaddress => ost.ipaddr,
          :hostname  => Socket.getaddrinfo(ost.ipaddr, nil)[0][2]
        )

        find_method        = host.detect_discovered_hypervisor(ost, ost.ipaddr)
        os_name, _ost_type = host.detect_discovered_os(ost)

        if Host.send(find_method, ost.ipaddr).nil?
          # It may have been added by someone else while we were discovering
          host.save!

          unless ost.hypervisor.include?(:ipmi)
            # Try to convert IP address to hostname and update host data
            netHostName = Host.get_hostname(ost.ipaddr)
            host.name = netHostName if netHostName

            EmsRefresh.save_operating_system_inventory(host, {:product_name => os_name, :product_type => os_type}) unless os_name.nil?
            EmsRefresh.save_hardware_inventory(host, {:cpu_type => "intel"})

            host.save!
          else
            # IPMI - Check if credentials were passed and try to scan host
            cred = (ost.credentials || {})[:ipmi]
            unless cred.nil? || cred[:userid].blank?
              ipmi = MiqIPMI.new(host.ipmi_address, cred[:userid], cred[:password])
              if ipmi.connected?
                _log.warn "IPMI connected to Host:<#{host.ipmi_address}> with User:<#{cred[:userid]}>"
                host.update_authentication(:ipmi => cred)
                host.scan
              else
                _log.warn "IPMI did not connect to Host:<#{host.ipmi_address}> with User:<#{cred[:userid]}>"
              end
            end
          end

          _log.info "#{host.name} created"
          AuditEvent.success(:event => "host_created", :target_id => host.id, :target_class => "Host", :message => "#{host.name} created")
        end
      else
        _log.info "NOT Discovered: #{self.ost_inspect(ost)}"
      end
    rescue => err
      _log.log_backtrace(err)
      AuditEvent.failure(:event => "host_created", :target_class => "Host", :message => "creating host, #{err}")
    end
  end

  def self.get_hostname(ipAddress)
    _log.info "Resolving hostname: [#{ipAddress}]"
    begin
      ret = Socket.gethostbyname(ipAddress)
      name = ret.first
    rescue => err
      _log.error "ERROR:  #{err}"
      return nil
    end
    _log.info "Resolved hostname: [#{name}] to [#{ipAddress}]"
    name
  end

  def ssh_users_and_passwords
    if has_authentication_type?(:remote)
      rl_user, rl_password = auth_user_pwd(:remote)
      su_user, su_password = auth_user_pwd(:root)
    else
      rl_user, rl_password = auth_user_pwd(:root)
      su_user, su_password = nil, nil
    end
    return rl_user, rl_password, su_user, su_password, {}
  end

  def connect_ssh(options={})
    require 'MiqSshUtil'

    rl_user, rl_password, su_user, su_password, additional_options = ssh_users_and_passwords
    options.merge!(additional_options)

    prompt_delay = VMDB::Config.new("vmdb").config.fetch_path(:ssh, :authentication_prompt_delay)
    options[:authentication_prompt_delay] = prompt_delay unless prompt_delay.nil?

    users = su_user.nil? ? rl_user : "#{rl_user}/#{su_user}"
    # Obfuscate private keys in the log with ****, so it's visible that field was used, but no user secret is exposed
    logged_options = options.dup
    logged_options[:key_data] = "[FILTERED]" if logged_options[:key_data]

    _log.info "Initiating SSH connection to Host:[#{name}] using [#{hostname}] for user:[#{users}].  Options:[#{logged_options.inspect}]"
    begin
      MiqSshUtil.shell_with_su(hostname, rl_user, rl_password, su_user, su_password, options) do |ssu, shell|
        _log.info "SSH connection established to [#{hostname}]"
        yield(ssu)
      end
      _log.info "SSH connection completed to [#{hostname}]"
    rescue Exception => err
      _log.error "SSH connection failed for [#{hostname}] with [#{err.class}: #{err}]"
      raise err
    end
  end

  def refresh_patches(ssu)
    return unless vmm_buildnumber && vmm_buildnumber != Patch.highest_patch_level(self)

    patches = []
    begin
      sb = ssu.shell_exec("esxupdate query")
      t = Time.now
      sb.each_line do |line|
        next if line =~ /-{5,}/ # skip any header/footer rows
        data = line.split(" ")
        # Find the lines we should skip
        begin
          next if data[1, 2].nil?
          dhash = {:name => data[0], :vendor => "VMware", :installed_on => Time.parse(data[1, 2].join(" ")).utc}
          next if dhash[:installed_on] - t >= 0
          dhash[:description] = data[3..-1].join(" ") unless data[3..-1].nil?
          patches << dhash
        rescue ArgumentError => err
          _log.log_backtrace(err)
          next
        rescue => err
          _log.log_backtrace(err)
        end
      end
    rescue => err
      #_log.log_backtrace(err)
    end

    Patch.refresh_patches(self, patches)
  end

  def refresh_services(ssu)
    begin
      xml = MiqXml.createDoc(:miq).root.add_element(:services)

      services = ssu.shell_exec("systemctl -a --type service")
      if services
        # If there is a systemd use only that, chconfig is calling systemd on the background, but has misleading results
        services = MiqLinux::Utils.parse_systemctl_list(services)
      else
      services = ssu.shell_exec("chkconfig --list")
      services = MiqLinux::Utils.parse_chkconfig_list(services)
      end

      services.each do |service|
        s = xml.add_element(:service,
                            'name'           => service[:name],
                            'systemd_load'   => service[:systemd_load],
                            'systemd_sub'    => service[:systemd_sub],
                            'description'    => service[:description],
                            'running'        => service[:running],
                            'systemd_active' => service[:systemd_active],
                            'typename'       => service[:typename])
        service[:enable_run_level].each  { |l| s.add_element(:enable_run_level,  'value' => l) } unless service[:enable_run_level].nil?
        service[:disable_run_level].each { |l| s.add_element(:disable_run_level, 'value' => l) } unless service[:disable_run_level].nil?
      end
      SystemService.add_elements(self, xml.root)
    rescue
    end
  end

  def refresh_linux_packages(ssu)
    begin
      pkg_xml = MiqXml.createDoc(:miq).root.add_element(:software).add_element(:applications)
      rpm_list = ssu.shell_exec("rpm -qa --queryformat '%{NAME}|%{VERSION}|%{ARCH}|%{GROUP}|%{RELEASE}|%{SUMMARY}\n'")
      rpm_list.each_line do |line|
        l = line.split('|')
        pkg_xml.add_element(:application, {'name' => l[0], 'version' => l[1], 'arch' => l[2], 'typename' => l[3], 'release' => l[4], 'description' => l[5]})
      end
      GuestApplication.add_elements(self, pkg_xml.root)
    rescue
    end
  end

  def refresh_user_groups(ssu)
    begin
      xml = MiqXml.createDoc(:miq)
      node = xml.root.add_element(:accounts)
      MiqLinux::Users.new(ssu).to_xml(node)
      Account.add_elements(self, xml.root)
    rescue
      #_log.log_backtrace($!)
    end
  end

  def refresh_ssh_config(ssu)
    begin
      self.ssh_permit_root_login = nil
      permit_list = ssu.shell_exec("grep PermitRootLogin /etc/ssh/sshd_config")
      # Setting default value to yes, which is default according to man sshd_config, if ssh returned something
      self.ssh_permit_root_login = 'yes' if permit_list
      permit_list.each_line do |line|
        la = line.split(' ')
        if la.length == 2
          next if la.first[0,1] == '#'
          self.ssh_permit_root_login = la.last.to_s.downcase
          break
        end
      end
    rescue
      #_log.log_backtrace($!)
    end
  end

  def refresh_fs_files(ssu)
    begin
      sp = HostScanProfiles.new(ScanItem.get_profile("host default"))
      files = sp.parse_data_files(ssu)
      EmsRefresh.save_filesystems_inventory(self, files) if files
    rescue
      #_log.log_backtrace($!)
    end
  end

  def refresh_logs
  end

  def refresh_firewall_rules
  end

  def refresh_advanced_settings
  end

  def refresh_ipmi_power_state
    if ipmi_config_valid?
      require 'miq-ipmi'
      address = ipmi_address

      if MiqIPMI.is_available?(address)
        ipmi = MiqIPMI.new(address, *auth_user_pwd(:ipmi))
        if ipmi.connected?
          self.power_state = ipmi.power_state
        else
          _log.warn("IPMI Login failed due to a bad username or password.")
        end
      else
        _log.info("IPMI is not available on this Host")
      end
    end
  end

  def refresh_ipmi
    if ipmi_config_valid?
      require 'miq-ipmi'
      address = ipmi_address

      if MiqIPMI.is_available?(address)
        ipmi = MiqIPMI.new(address, *auth_user_pwd(:ipmi))
        if ipmi.connected?
          self.power_state = ipmi.power_state
          mac = ipmi.mac_address
          self.mac_address = mac unless mac.blank?

          hw_info = {:manufacturer => ipmi.manufacturer, :model => ipmi.model}
          if hardware.nil?
            EmsRefresh.save_hardware_inventory(self, hw_info)
          else
            hardware.update_attributes(hw_info)
          end
        else
          _log.warn("IPMI Login failed due to a bad username or password.")
        end
      else
        _log.info("IPMI is not available on this Host")
      end
    end
  end

  def ipmi_config_valid?(include_mac_addr=false)
    if has_credentials?(:ipmi) && !ipmi_address.blank?
      if include_mac_addr == true
        if mac_address.blank?
          return false
        else
          return true
        end
      else
        return true
      end
    else
      return false
    end
  end
  alias_method :ipmi_enabled, :ipmi_config_valid?

  def self.ready_for_provisioning?(ids)
    errors = ActiveModel::Errors.new(self)
    hosts = find_all_by_id(ids)
    missing = ids - hosts.collect(&:id)
    errors.add(:missing_ids, "Unable to find Hosts with the following ids #{missing.inspect}") unless missing.empty?

    hosts.each do |host|
      begin
        if host.ipmi_config_valid?(true) == false
          errors.add(:"Error -", "Host not available for provisioning. Name: [#{host.name}]")
        end
      rescue => err
        errors.add(:error_checking, "Error, '#{err.message}, checking Host for provisioning: Name: [#{host.name}]")
      end
    end

    return errors.empty? ? true : errors
  end

  def set_custom_field(attribute, value)
    return unless vmm_vendor == "VMware"
    raise "Host has no EMS, unable to set custom attribute" unless ext_management_system

    ext_management_system.set_custom_field(self, :attribute => attribute, :value => value)
  end

  def quickStats
    return @qs if @qs
    return {} unless vmm_vendor == "VMware"

    begin
      raise "Host has no EMS, unable to get host statistics" unless ext_management_system

      @qs = ext_management_system.host_quick_stats(self)
    rescue => err
      _log.warn("Error '#{err.message}' encountered attempting to get host quick statistics")
      return {}
    end
    return @qs
  end

  def current_memory_usage
    quickStats["overallMemoryUsage"].to_i
  end

  def current_cpu_usage
    quickStats["overallCpuUsage"].to_i
  end

  def current_memory_headroom
    ram_size - current_memory_usage
  end

  def ram_size
    return 0 if hardware.nil?
    return hardware.memory_cpu.to_i
  end

  def firewall_rules
    return [] if operating_system.nil?
    return operating_system.firewall_rules
  end

  def enforce_policy(vm, event)
    inputs = {:vm => vm, :host => self}
    MiqEvent.raise_evm_event(vm, event, inputs)
  end

  def first_cat_entry(name)
    Classification.first_cat_entry(name, self)
  end

  def self.check_for_vms_to_scan
    _log.debug "Checking for VMs that are scheduled to be scanned"

    hosts = MiqServer.my_server.zone.hosts
    MiqPreloader.preload(hosts, :vms)
    hosts.each do |h|
      next if h.scan_frequency.to_i == 0

      h.vms.each do |vm|
        if vm.last_scan_attempt_on.nil? || h.scan_frequency.to_i.seconds.ago.utc > vm.last_scan_attempt_on
          begin
            _log.info("Creating scan job on [(#{vm.class.name}) #{vm.name}]")
            vm.scan
          rescue => err
            _log.log_backtrace(err)
          end
        end
      end
    end
  end

  # TODO: Rename this to scan_queue and rename scan_from_queue to scan to match
  #   standard from other places.
  def scan(userid = "system", options={})
    log_target = "#{self.class.name} name: [#{name}], id: [#{id}]"

    task = MiqTask.create(:name => "SmartState Analysis for '#{name}' ", :userid => userid)

    _log.info("Requesting scan of #{log_target}")
    begin
      MiqEvent.raise_evm_job_event(self, :type => "scan", :prefix => "request")
    rescue => err
      _log.warn("Error raising request scan event for #{log_target}: #{err.message}")
      return
    end

    _log.info("Queuing scan of #{log_target}")
    timeout = (VMDB::Config.new("vmdb").config.fetch_path(:host_scan, :queue_timeout) || 20.minutes).to_i_with_method
    cb = {:class_name => task.class.name, :instance_id => task.id, :method_name => :queue_callback_on_exceptions, :args => ['Finished']}
    MiqQueue.put(
      :class_name   => self.class.name,
      :instance_id  => id,
      :args         => [task.id],
      :method_name  => "scan_from_queue",
      :miq_callback => cb,
      :msg_timeout  => timeout,
      :zone         => my_zone
    )
  end

  def scan_from_queue(taskid=nil)
    unless taskid.nil?
      task = MiqTask.find_by_id(taskid)
      task.state_active  if task
    end

    log_target = "#{self.class.name} name: [#{name}], id: [#{id}]"

    _log.info("Scanning #{log_target}...")

    task.update_status("Active", "Ok", "Scanning") if task

    _dummy, t = Benchmark.realtime_block(:total_time) do

      # Firewall Rules and Advanced Settings go through EMS so we don't need Host credentials
      _log.info("Refreshing Firewall Rules for #{log_target}")
      task.update_status("Active", "Ok", "Refreshing Firewall Rules") if task
      Benchmark.realtime_block(:refresh_firewall_rules) { refresh_firewall_rules }

      _log.info("Refreshing Advanced Settings for #{log_target}")
      task.update_status("Active", "Ok", "Refreshing Advanced Settings") if task
      Benchmark.realtime_block(:refresh_advanced_settings) { refresh_advanced_settings }

      if ext_management_system.nil?
        _log.info("Refreshing IPMI information for #{log_target}")
        task.update_status("Active", "Ok", "Refreshing IPMI Information") if task
        Benchmark.realtime_block(:refresh_ipmi) { refresh_ipmi }
      end

      save

      # Skip SSH for ESXi hosts
      unless is_vmware_esxi?
        if hostname.blank?
          _log.warn "No hostname defined for #{log_target}"
          task.update_status("Finished", "Warn", "Scanning incomplete due to missing hostname")  if task
          return
        end

        update_ssh_auth_status! if respond_to?(:update_ssh_auth_status!)

        if missing_credentials?
          _log.warn "No credentials defined for #{log_target}"
          task.update_status("Finished", "Warn", "Scanning incomplete due to Credential Issue")  if task
          return
        end

        begin
          connect_ssh do |ssu|
            _log.info("Refreshing Patches for #{log_target}")
            task.update_status("Active", "Ok", "Refreshing Patches") if task
            Benchmark.realtime_block(:refresh_patches) { refresh_patches(ssu) }

            _log.info("Refreshing Services for #{log_target}")
            task.update_status("Active", "Ok", "Refreshing Services") if task
            Benchmark.realtime_block(:refresh_services) { refresh_services(ssu) }

            _log.info("Refreshing Linux Packages for #{log_target}")
            task.update_status("Active", "Ok", "Refreshing Linux Packages") if task
            Benchmark.realtime_block(:refresh_linux_packages) { refresh_linux_packages(ssu) }

            _log.info("Refreshing User Groups for #{log_target}")
            task.update_status("Active", "Ok", "Refreshing User Groups") if task
            Benchmark.realtime_block(:refresh_user_groups) { refresh_user_groups(ssu) }

            _log.info("Refreshing SSH Config for #{log_target}")
            task.update_status("Active", "Ok", "Refreshing SSH Config") if task
            Benchmark.realtime_block(:refresh_ssh_config) { refresh_ssh_config(ssu) }

            _log.info("Refreshing FS Files for #{log_target}")
            task.update_status("Active", "Ok", "Refreshing FS Files") if task
            Benchmark.realtime_block(:refresh_fs_files) { refresh_fs_files(ssu) }

            # refresh_openstack_services should run after refresh_services and refresh_fs_files
            if respond_to?(:refresh_openstack_services)
              _log.info("Refreshing OpenStack Services for #{log_target}")
              task.update_status("Active", "Ok", "Refreshing OpenStack Services") if task
              Benchmark.realtime_block(:refresh_openstack_services) { refresh_openstack_services(ssu) }
            end

            save
          end
        rescue Net::SSH::HostKeyMismatch
          # Keep from dumping stack trace for this error which is sufficiently logged in the connect_ssh method
        rescue => err
          _log.log_backtrace(err)
        end
      end

      _log.info("Refreshing Log information for #{log_target}")
      task.update_status("Active", "Ok", "Refreshing Log Information") if task
      Benchmark.realtime_block(:refresh_logs) { refresh_logs }

      _log.info("Saving state for #{log_target}")
      task.update_status("Active", "Ok", "Saving Drift State") if task
      Benchmark.realtime_block(:save_driftstate) { save_drift_state }

      begin
        MiqEvent.raise_evm_job_event(self, :type => "scan", :suffix => "complete")
      rescue => err
        _log.warn("Error raising complete scan event for #{log_target}: #{err.message}")
      end

    end

    task.update_status("Finished", "Ok", "Scanning Complete") if task
    _log.info("Scanning #{log_target}...Complete - Timings: #{t.inspect}")
  end

  def ssh_run_script(script)
    connect_ssh {|ssu| return ssu.shell_exec(script)}
  end

  def add_ems_events(event_hash)
    event_hash[:events].each do |event|
      event[:ems_id] = ems_id
      event[:host_name] = name
      event[:host_id] = id
      begin
        EmsEvent.add(ems_id, event)
      rescue => err
        _log.log_backtrace(err)
      end
    end
  end

  # Virtual columns for owning cluster, folder and datacenter
  def v_owning_cluster
    o = owning_cluster
    o ? o.name : ""
  end

  def v_owning_folder
    o = owning_folder
    o ? o.name : ""
  end

  def v_owning_datacenter
    o = owning_datacenter
    o ? o.name : ""
  end

  # Virtual cols for relationship counts
  def v_total_storages
    storages.size
  end

  def v_total_vms
    vms.size
  end

  def v_total_miq_templates
    miq_templates.size
  end

  def miq_scsi_luns
    luns = []
    return luns if hardware.nil?

    hardware.storage_adapters.each do |sa|
      sa.miq_scsi_targets.each do |st|
        luns.concat(st.miq_scsi_luns)
      end
    end
    luns
  end

  def enabled_inbound_ports
    get_ports("in")
  end

  def enabled_outbound_ports
    get_ports("out")
  end

  def enabled_tcp_inbound_ports
    get_ports("in", "tcp")
  end

  def enabled_tcp_outbound_ports
    get_ports("out", "tcp")
  end

  def enabled_udp_inbound_ports
    get_ports("in", "udp")
  end

  def enabled_udp_outbound_ports
    get_ports("out", "udp")
  end

  def all_enabled_ports
    get_ports
  end

  def get_ports(direction = nil, host_protocol = nil)
    return [] if operating_system.nil?

    conditions = {:enabled => true}
    conditions[:direction] = direction if direction
    conditions[:host_protocol] = host_protocol if host_protocol

    operating_system.firewall_rules.where(conditions)
      .flat_map { |rule| rule.port_range.to_a }
      .uniq.sort
  end

  def service_names
    system_services.collect(&:name).uniq.sort
  end

  def enabled_run_level_0_services
    get_service_names(0)
  end

  def enabled_run_level_1_services
    get_service_names(2)
  end

  def enabled_run_level_2_services
    get_service_names(2)
  end

  def enabled_run_level_3_services
    get_service_names(3)
  end

  def enabled_run_level_4_services
    get_service_names(4)
  end

  def enabled_run_level_5_services
    get_service_names(5)
  end

  def enabled_run_level_6_services
    get_service_names(6)
  end

  def get_service_names(*args)
    if args.length == 0
      services = host_services
    elsif args.length == 1
      services = host_services.where("enable_run_levels LIKE ?", "%#{args.first}%")
    end
    services.order(:name).uniq.pluck(:name)
  end

  def control_supported?
    !(vmm_vendor == VENDOR_TYPES["vmware"] && vmm_product == "Workstation")
  end

  def event_where_clause(assoc=:ems_events)
    case assoc.to_sym
    when :ems_events
      ["host_id = ? OR dest_host_id = ?", id, id]
    when :policy_events
      ["host_id = ?", id]
    end
  end

  def has_vm_scan_affinity?
    with_relationship_type("vm_scan_affinity") { parent_count > 0 }
  end

  def vm_scan_affinity=(list)
    list = [list].flatten
    with_relationship_type("vm_scan_affinity") do
      remove_all_parents
      list.each { |parent| set_parent(parent) }
    end
    true
  end
  alias set_vm_scan_affinity vm_scan_affinity=

  def vm_scan_affinity
    with_relationship_type("vm_scan_affinity") { parents }
  end
  alias get_vm_scan_affinity vm_scan_affinity

  def processes
    operating_system.try(:processes) || []
  end

  def event_logs
    operating_system.try(:event_logs) || []
  end

  def get_reserve(field)
    default_resource_pool.try(:send, field)
  end

  def cpu_reserve
    get_reserve(:cpu_reserve)
  end

  def memory_reserve
    get_reserve(:memory_reserve)
  end

  def total_vm_cpu_reserve
    vms.inject(0) { |t, vm| t + (vm.cpu_reserve || 0) }
  end

  def total_vm_memory_reserve
    vms.inject(0) { |t, vm| t + (vm.memory_reserve || 0) }
  end

  def total_vcpus
    logical_cpus || 0
  end

  def vcpus_per_core
    cores = total_vcpus
    return 0 if cores == 0

    total_vm_vcpus = vms.inject(0) {|t, vm| t += (vm.num_cpu || 0) }
    (total_vm_vcpus / cores)
  end

  def num_cpu
    hardware.nil? ? 0 : hardware.numvcpus
  end

  def logical_cpus
    hardware.nil? ? 0 : hardware.logical_cpus
  end

  def cores_per_socket
    hardware.nil? ? 0 : hardware.cores_per_socket
  end

  def domain
    names = hostname.to_s.split(',').first.to_s.split('.')
    return names[1..-1].join('.') unless names.blank?
    nil
  end

  def base_storage_extents
    miq_cim_instance.try(:base_storage_extents) || []
  end

  def base_storage_extents_size
    miq_cim_instance.try(:base_storage_extents_size) || 0
  end

  def storage_systems
    miq_cim_instance.try(:storage_systems) || []
  end

  def storage_systems_size
    miq_cim_instance.try(:storage_systems_size) || 0
  end

  def storage_volumes
    miq_cim_instance.try(:storage_volumes) || []
  end

  def storage_volumes_size
    miq_cim_instance.try(:storage_volumes_size) || 0
  end

  def file_shares
    miq_cim_instance.try(:file_shares) || []
  end

  def file_shares_size
    miq_cim_instance.try(:file_shares_size) || 0
  end

  def logical_disks
    miq_cim_instance.try(:logical_disks) || []
  end

  def logical_disks_size
    miq_cim_instance.try(:logical_disks_size) || 0
  end

  def create_pxe_install_request(values, requester_id, auto_approve = false)
    values[:host_ids] = [id]
    MiqHostProvisionRequest.create_request(values, requester_id, auto_approve)
  end

  def update_pxe_install_request(request, values, requester_id)
    values[:host_ids] = [id]
    MiqHostProvisionRequest.update_request(request, values, requester_id)
  end

  #
  # Metric methods
  #

  PERF_ROLLUP_CHILDREN = :vms

  def perf_rollup_parent(interval_name = nil)
    ems_cluster || (ext_management_system if interval_name == 'realtime')
  end

  def get_performance_metric(capture_interval, metric, range, function = nil)
    # => capture_interval = 'realtime' | 'hourly' | 'daily'
    # => metric = perf column name (real or virtual)
    # => function = :avg | :min | :max
    # => range = [start_time, end_time] | start_time | number in seconds to go back

    time_range = if range.kind_of?(Array)
                   range
                 elsif range.kind_of?(Time)
                   [range.utc, Time.now.utc]
                 elsif range.kind_of?(String)
                   [range.to_time(:utc), Time.now.utc]
                 elsif range.kind_of?(Integer)
                   [range.seconds.ago.utc, Time.now.utc]
                 else
                   raise "Range #{range} is invalid"
                 end

    klass = case capture_interval.to_s
            when 'realtime' then HostMetric
            else HostPerformance
            end

    perfs = klass.where(
      [
        "resource_id = ? AND capture_interval_name = ? AND timestamp >= ? AND timestamp <= ?",
        id,
        capture_interval.to_s,
        time_range[0],
        time_range[1]
      ]
    ).order "timestamp"

    if capture_interval.to_sym == :realtime && metric.to_s.starts_with?("v_pct_cpu_")
      vm_vals_by_ts = get_pct_cpu_metric_from_child_vm_performances(metric, capture_interval, time_range)
      values = perfs.collect { |p| vm_vals_by_ts[p.timestamp] || 0 }
    else
      values = perfs.collect(&metric.to_sym)
    end

    # => returns value | [array of values] (if function.nil?)
    return values if function.nil?

    case function.to_sym
    when :min, :max then return values.send(function)
    when :avg
      return 0 if values.length == 0
      return (values.compact.sum / values.length)
    else
      raise "Function #{function} is invalid, should be one of :min, :max, :avg or nil"
    end
  end

  def get_pct_cpu_metric_from_child_vm_performances(metric, capture_interval, time_range)
    klass = case capture_interval.to_s
            when 'realtime' then VmMetric
            else VmPerformance
            end

    vm_perfs = klass.all(:conditions => [
      "parent_host_id = ? AND capture_interval_name = ? AND timestamp >= ? AND timestamp <= ?",
      id,
      capture_interval.to_s,
      time_range[0],
      time_range[1]
    ])

    perf_hash = {}
    vm_perfs.each do |p|
      perf_hash[p.timestamp] ||= []
      perf_hash[p.timestamp] << p.send(metric)
    end

    perf_hash.each_key do |ts|
      tot = perf_hash[ts].compact.sum
      perf_hash[ts] = perf_hash[ts].empty? ? 0 : (tot / perf_hash[ts].length.to_f)
    end
    perf_hash
  end

  # Host Discovery Types and Platforms

  def self.host_discovery_types
    HOST_DISCOVERY_TYPES.values
  end

  def self.host_create_os_types
    HOST_CREATE_OS_TYPES
  end

  def has_compliance_policies?
    _, plist = MiqPolicy.get_policies_for_target(self, "compliance", "host_compliance_check")
    !plist.blank?
  end

  def self.node_types
    return :mixed_hosts if count_of_openstack_hosts > 0 && count_of_non_openstack_hosts > 0
    return :openstack   if count_of_openstack_hosts > 0
    :non_openstack
  end

  def self.count_of_openstack_hosts
    ems = EmsOpenstackInfra.pluck(:id)
    Host.where(:ems_id => ems).count
  end

  def self.count_of_non_openstack_hosts
    ems = EmsOpenstackInfra.pluck(:id)
    Host.where(Host.arel_table[:ems_id].not_in(ems)).count
  end

  def openstack_host?
    ext_management_system.class == EmsOpenstackInfra
  end
end
