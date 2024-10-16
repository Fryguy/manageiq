class HostOpenstackInfra < Host
  belongs_to :availability_zone

  has_many   :host_service_group_openstacks, :foreign_key => :host_id, :dependent => :destroy

  # TODO(lsmola) for some reason UI can't handle joined table cause there is hardcoded somewhere that it selects
  # DISTINCT id, with joined tables, id needs to be prefixed with table name. When this is figured out, replace
  # cloud tenant with rails relations
  # in /app/models/miq_report/search.rb:83 there is select(:id) by hard
  # has_many :vms, :class_name => 'VmOpenstack', :foreign_key => :host_id
  # has_many :cloud_tenants, :through => :vms, :uniq => true

  def cloud_tenants
    CloudTenant.where(:id => vms.collect(&:cloud_tenant_id).uniq)
  end

  def ssh_users_and_passwords
    # HostOpenstackInfra is using auth key set on ext_management_system level, not individual hosts
    rl_user, auth_key = self.auth_user_keypair(:ssh_keypair)
    rl_password = nil
    su_user, su_password = nil, nil
    # TODO(lsmola) make sudo user work with password. We will not probably support su, as root will not have password
    # allowed. Passwordless sudo is good enough for now
    passwordless_sudo = rl_user != 'root'

    return rl_user, rl_password, su_user, su_password, {:key_data => auth_key, :passwordless_sudo => passwordless_sudo}
  end

  def get_parent_keypair(type = nil)
    # Get private key defined on Provider level, in the case all hosts has the same user
    self.ext_management_system.try(:authentication_type, type)
  end

  def authentication_best_fit(type = nil)
    # First check for Host level credentials with filled private key, this way we can override auth credentials per
    # host. Otherwise host level auth will hold only state of auth for the given host. We allow only auth with private
    # key for OpenstackInfra hosts
    auth = authentication_type(type)
    return auth if auth && auth.auth_key
    # Not defined auth on this specific host, get auth defined for all hosts from the provider.
    get_parent_keypair(:ssh_keypair)
  end

  def authentication_status
    # Auth status is always stored in Host's auth record
    self.authentication_type(:ssh_keypair).try(:status) || "None"
  end

  def update_ssh_auth_status!
    unless cred = self.authentication_type(:ssh_keypair)
      # Creating just Auth status placeholder, the credentials are stored in parent or this auth, parent is
      # EmsOpenstackInfra in this case. We will create Auth per Host where we will store state, if it not exists
      cred = AuthKeyPairOpenstackInfra.new(:name => "#{self.class.name} #{self.name}", :authtype => :ssh_keypair,
                                           :resource_id => id, :resource_type => 'Host')
    end

    begin
      verified = self.verify_credentials_with_ssh
    rescue StandardError, NotImplementedError
      verified = false
      _log.warn("#{$!.inspect}")
    end

    if verified
      cred.status = 'Valid'
      cred.save
    else
      if self.hostname && !self.missing_credentials?(:ssh_keypair)
        # The credentials exists and hostname is set and we are not able to verify, go to error state
        cred.status = 'Error'
      else
        # Hostname or credentials do not exists, set None.
        cred.status = 'None'
      end
      cred.save
    end
  end

  def refresh_openstack_services(ssu)
    openstack_status = ssu.shell_exec("openstack-status")
    services = MiqLinux::Utils.parse_openstack_status(openstack_status)
    self.host_service_group_openstacks = services.map do |service|
      # find OpenstackHostServiceGroup records by host and name and initialize if not found
      host_service_group_openstacks.where(:name => service['name'])
        .first_or_initialize.tap do |host_service_group_openstack|
        # find SystemService records by host
        # filter SystemService records by names from openstack-status results
        sys_services = system_services.where(:name => service['services'].map { |ser| ser['name'] })
        # associate SystemService record with OpenstackHostServiceGroup
        host_service_group_openstack.system_services = sys_services

        # find Filesystem records by host
        # filter Filesystem records by names
        # we assume that /etc/<service name>* is good enough pattern
        dir_name = "/etc/#{host_service_group_openstack.name.downcase.gsub(/\sservice.*/, '')}"

        matcher = Filesystem.arel_table[:name].matches("#{dir_name}%")
        files = filesystems.where(matcher)
        host_service_group_openstack.filesystems = files

        # save all changes
        host_service_group_openstack.save
      end
    end
  rescue => err
    _log.log_backtrace(err)
    raise err
  end
end
