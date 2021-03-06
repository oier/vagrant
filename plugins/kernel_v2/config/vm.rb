require "pathname"

require "vagrant"

require File.expand_path("../vm_provider", __FILE__)
require File.expand_path("../vm_provisioner", __FILE__)
require File.expand_path("../vm_subvm", __FILE__)

module VagrantPlugins
  module Kernel_V2
    class VMConfig < Vagrant.plugin("2", :config)
      DEFAULT_VM_NAME = :default

      attr_accessor :auto_port_range
      attr_accessor :base_mac
      attr_accessor :box
      attr_accessor :box_url
      attr_accessor :guest
      attr_accessor :host_name
      attr_reader :forwarded_ports
      attr_reader :shared_folders
      attr_reader :networks
      attr_reader :providers
      attr_reader :provisioners

      def initialize
        @forwarded_ports = []
        @shared_folders = {}
        @networks = []
        @provisioners = []

        # The providers hash defaults any key to a provider object
        @providers = Hash.new do |hash, key|
          hash[key] = VagrantConfigProvider.new(key, nil)
        end
      end

      # Custom merge method since some keys here are merged differently.
      def merge(other)
        result = super
        result.instance_variable_set(:@forwarded_ports, @forwarded_ports + other.forwarded_ports)
        result.instance_variable_set(:@shared_folders, @shared_folders.merge(other.shared_folders))
        result.instance_variable_set(:@networks, @networks + other.networks)
        result.instance_variable_set(:@provisioners, @provisioners + other.provisioners)
        result
      end

      def forward_port(guestport, hostport, options=nil)
        @forwarded_ports << {
          :name       => "#{guestport.to_s(32)}-#{hostport.to_s(32)}",
          :guestport  => guestport,
          :hostport   => hostport,
          :protocol   => :tcp,
          :adapter    => 1,
          :auto       => false
        }.merge(options || {})
      end

      def share_folder(name, guestpath, hostpath, opts=nil)
        @shared_folders[name] = {
          :guestpath => guestpath.to_s,
          :hostpath => hostpath.to_s,
          :create => false,
          :owner => nil,
          :group => nil,
          :nfs   => false,
          :transient => false,
          :extra => nil
        }.merge(opts || {})
      end

      def network(type, *args)
        @networks << [type, args]
      end

      # Configures a provider for this VM.
      #
      # @param [Symbol] name The name of the provider.
      def provider(name, &block)
        # TODO: Error if a provider is defined multiple times.
        @providers[name] = VagrantConfigProvider.new(name, block)
      end

      def provision(name, options=nil, &block)
        @provisioners << VagrantConfigProvisioner.new(name, options, &block)
      end

      def defined_vms
        @defined_vms ||= {}
      end

      # This returns the keys of the sub-vms in the order they were
      # defined.
      def defined_vm_keys
        @defined_vm_keys ||= []
      end

      def define(name, options=nil, &block)
        name = name.to_sym
        options ||= {}

        # Add the name to the array of VM keys. This array is used to
        # preserve the order in which VMs are defined.
        defined_vm_keys << name

        # Add the SubVM to the hash of defined VMs
        if !defined_vms[name]
          defined_vms[name] ||= VagrantConfigSubVM.new
        end

        defined_vms[name].options.merge!(options)
        defined_vms[name].push_proc(&block) if block
      end

      def finalize!
        # If we haven't defined a single VM, then we need to define a
        # default VM which just inherits the rest of the configuration.
        define(DEFAULT_VM_NAME) if defined_vm_keys.empty?
      end

      def validate(env, errors)
        errors.add(I18n.t("vagrant.config.vm.box_missing")) if !box
        errors.add(I18n.t("vagrant.config.vm.box_not_found", :name => box)) if box && !box_url && !env.boxes.find(box, :virtualbox)
        errors.add(I18n.t("vagrant.config.vm.base_mac_invalid")) if env.boxes.find(box, :virtualbox) && !base_mac

        shared_folders.each do |name, options|
          hostpath = Pathname.new(options[:hostpath]).expand_path(env.root_path)

          if !hostpath.directory? && !options[:create]
            errors.add(I18n.t("vagrant.config.vm.shared_folder_hostpath_missing",
                       :name => name,
                       :path => options[:hostpath]))
          end

          if options[:nfs] && (options[:owner] || options[:group])
            # Owner/group don't work with NFS
            errors.add(I18n.t("vagrant.config.vm.shared_folder_nfs_owner_group",
                              :name => name))
          end
        end

        # Validate some basic networking
        #
        # TODO: One day we need to abstract this out, since in the future
        # providers other than VirtualBox will not be able to satisfy
        # all types of networks.
        networks.each do |type, args|
          if type == :hostonly && args[0] == :dhcp
            # Valid. There is no real way this can be invalid at the moment.
          elsif type == :hostonly
            # Validate the host-only network
            ip      = args[0]

            if !ip
              errors.add(I18n.t("vagrant.config.vm.network_ip_required"))
            else
              ip_parts = ip.split(".")

              if ip_parts.length != 4
                errors.add(I18n.t("vagrant.config.vm.network_ip_invalid",
                                  :ip => ip))
              elsif ip_parts.last == "1"
                errors.add(I18n.t("vagrant.config.vm.network_ip_ends_one",
                                  :ip => ip))
              end
            end
          elsif type == :bridged
          else
            # Invalid network type
            errors.add(I18n.t("vagrant.config.vm.network_invalid",
                              :type => type.to_s))
          end
        end

        # Each provisioner can validate itself
        provisioners.each do |prov|
          prov.validate(env, errors)
        end
      end
    end
  end
end
