class ManageIQ::Providers::EmbeddedAnsible::AutomationManager::OpenstackCredential < ManageIQ::Providers::EmbeddedAnsible::AutomationManager::CloudCredential
  def self.display_name(number = 1)
    n_('Credential (OpenStack)', 'Credentials (OpenStack)', number)
  end
end
