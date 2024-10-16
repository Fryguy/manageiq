require_relative '../../bundler_setup'
require 'log4r'
require 'VMwareWebService/MiqVim'
require 'VMwareWebService/MiqVimBroker'

#
# Formatter to output log messages to the console.
#
class ConsoleFormatter < Log4r::Formatter
	def format(event)
		(event.data.kind_of?(String) ? event.data : event.data.inspect) + "\n"
	end
end
$vim_log = Log4r::Logger.new 'toplog'
Log4r::StderrOutputter.new('err_console', :level=>Log4r::OFF, :formatter=>ConsoleFormatter)
$vim_log.add 'err_console'

# $miq_wiredump = true
TARGET_HOST		= raise "please define"
HOST_USERNAME	= ""
HOST_PASSWORD	= ""
CLUSTER_NAME	= ""

miqCluster	= nil
miqHost		= nil

broker = MiqVimBroker.new(:client)
vim = MiqVim.new(SERVER, USERNAME, PASSWORD)

begin
	
    puts "vim.class: #{vim.class}"
    puts "#{vim.server} is #{(vim.isVirtualCenter? ? 'VC' : 'ESX')}"
    puts "API version: #{vim.apiVersion}"

	puts
	miqHost = vim.getVimHost(TARGET_HOST)
	puts "Got object for host: #{miqHost.name}"
	
	#
	# It appears that this returns true for a VM running ESX,
	# even though it doesn't seem to support standby.
	#
	unless miqHost.standbySupported?
		puts "Host does not support standby"
		exit
	end
	
	puts
	puts "Putting host in StandBy Mode..."
	miqHost.powerDownHostToStandBy
	puts "done."
	

rescue => err
    puts err.to_s
    puts err.backtrace.join("\n")
ensure
	miqCluster.release if miqCluster
    vim.disconnect
end
