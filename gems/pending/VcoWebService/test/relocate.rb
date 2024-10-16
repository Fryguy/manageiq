require_relative '../../bundler_setup'
require 'VcoWebService/MiqVcoClientBase'

begin
	work_flow_name	= "Relocate VM"
	target_vm		= 'Fedora7'
	to_host			= TARGET_HOST
	
	vco = MiqVcoClientBase.new(SOURCE_HOST, USERNAME, PASSWORD)
	
	wf = vco.getWorkflowsWithName(work_flow_name)
	vco.dumpObj(wf)
	
	vms = vco.findByFilter("VC:VirtualMachine", 'name' => target_vm)[0]
	vco.dumpObj(vms)
	
	#
	# Keep VM on same datastore.
	#
	ds = vco.findRelation("VC:VirtualMachine", vms.id, "getDatastore()")
	vco.dumpObj(ds)
	
	hs = vco.findByFilter("VC:HostSystem", 'name' => to_host)[0]
	vco.dumpObj(hs)
	
	cr = vco.findByFilter("VC:ComputeResource", 'name' => to_host)[0]
	vco.dumpObj(cr)
	
	rp = vco.findRelation("VC:ComputeResource", cr.id, "getResourcePool()")
	vco.dumpObj(rp)
	
	inputs = VcoArray.new('ArrayOfWorkflowTokenAttribute') do |ia|
		ia << VcoHash.new('WorkflowTokenAttribute') do |i|
			i.name	= 'vm'
			i.type	= vms.type
			i.value	= vms.dunesUri
		end
		ia << VcoHash.new('WorkflowTokenAttribute') do |i|
			i.name	= 'datastore'
			i.type	= ds.type
			i.value	= ds.dunesUri
		end
		ia << VcoHash.new('WorkflowTokenAttribute') do |i|
			i.name	= 'pool'
			i.type	= rp.type
			i.value	= rp.dunesUri
		end
		ia << VcoHash.new('WorkflowTokenAttribute') do |i|
			i.name	= 'host'
			i.type	= hs.type
			i.value	= hs.dunesUri
		end
	end
	
	rv = vco.executeWorkflow(wf.id, inputs)
	vco.dumpObj(rv)
	puts
	puts "***** Work flow state: #{rv.globalState}"
	
rescue => err
	puts err.to_s
	puts err.backtrace.join("\n")
end
