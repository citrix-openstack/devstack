#!/bin/bash

# This script must be run on a XenServer or XCP machine
#
# It creates a DomU VM that runs OpenStack services
#
# For more details see: README.md

set -o errexit
set -o nounset
set -o xtrace

# This directory
THIS_DIR=$(cd $(dirname "$0") && pwd)

# xapi functions
. $THIS_DIR/functions

# Abort if localrc is not set
if [ ! -e ../../localrc ]; then
    log_error << EOF
You must have a localrc with ALL necessary passwords defined before proceeding.
See the xen README for required passwords.
EOF
    exit 1
fi

# Source lower level functions
. $THIS_DIR/../../functions

# Include onexit commands
. $THIS_DIR/scripts/on_exit.sh

#
# Get Settings
#

# Source params - override xenrc params in your localrc to suit your taste
source $THIS_DIR/xenrc

#
# Uninstall Virtual Machines
#
IFS=,
for vm_name_label in $(xe vm-list params=name-label --minimal); do
    # Wipe previous OpenStack VMs
    if [[ "$vm_name_label" == "$GUEST_NAME" ]]; then
        if [[ "$OSDOMU_REINSTALL" == "true" ]]; then
            uninstall_vm "$vm_name_label"
        fi
    # Destroy any instances that were launched
    elif [[ "$vm_name_label" =~ "instance" ]]; then
        uninstall_vm "$vm_name_label"
    fi
done
unset IFS

# Destroy orphaned vdis
for uuid in `xe vdi-list | grep -1 Glance | grep uuid | sed "s/.*\: //g"`; do
    xe vdi-destroy uuid=$uuid
done

SNAPSHOT_JEOS="$GUEST_NAME - JEOS"

if snapshot_missing "$SNAPSHOT_JEOS"; then
    HOST_IP=$(xenapi_ip_on "$MGT_BRIDGE_OR_NET_NAME")

    if [ -z "${PRESEED_URL:-}" ]; then
        PRESEED_URL="${HOST_IP}/devstackubuntupreseed.cfg"
        HTTP_SERVER_LOCATION="/opt/xensource/www"
        if [ ! -e $HTTP_SERVER_LOCATION ]; then
            HTTP_SERVER_LOCATION="/var/www/html"
            mkdir -p $HTTP_SERVER_LOCATION
        fi
        cp -f $THIS_DIR/devstackubuntupreseed.cfg $HTTP_SERVER_LOCATION

        sed \
            -e "s,\(d-i mirror/http/hostname string\).*,\1 $UBUNTU_INST_HTTP_HOSTNAME,g" \
            -e "s,\(d-i mirror/http/directory string\).*,\1 $UBUNTU_INST_HTTP_DIRECTORY,g" \
            -e "s,\(d-i mirror/http/proxy string\).*,\1 $UBUNTU_INST_HTTP_PROXY,g" \
            -i "${HTTP_SERVER_LOCATION}/devstackubuntupreseed.cfg"
    fi

    clone_template_as_vm "$TEMPLATE_TO_USE" "$GUEST_NAME"
    set_vm_memory "$GUEST_NAME" "$OSDOMU_MEM_MB"
    add_boot_disk "$GUEST_NAME" "$OSDOMU_VDI_GB"
    append_kernel_cmdline "$GUEST_NAME" "$(\
        print_essential_installer_args \
            "$UBUNTU_INST_LOCALE" \
            "$UBUNTU_INST_KEYBOARD" \
            "$PRESEED_URL")"

    if [ "$UBUNTU_INST_IP" != "dhcp" ]; then
        append_kernel_cmdline "$GUEST_NAME" "$(\
            print_installer_args_for_static_ip \
                "$UBUNTU_INST_NAMESERVERS" \
                "$UBUNTU_INST_IP" \
                "$UBUNTU_INST_NETMASK" \
                "$UBUNTU_INST_GATEWAY")"
    fi

    set_other_config_for_netinstall "$GUEST_NAME" \
        "$UBUNTU_INST_HTTP_HOSTNAME" \
        "$UBUNTU_INST_HTTP_DIRECTORY" \
        "$UBUNTU_INST_RELEASE" \
        "$UBUNTU_INST_ARCH"

    if ! [ -z "$UBUNTU_INST_HTTP_PROXY" ]; then
        set_install_proxy "$GUEST_NAME" "$UBUNTU_INST_HTTP_PROXY"
    fi

    add_interface "$GUEST_NAME" "$UBUNTU_INST_BRIDGE_OR_NET_NAME" "0"

    set_halt_on_restart "$GUEST_NAME"

    start_vm "$GUEST_NAME"

    log_info << EOF
Wait for install to finish

Progress in-VM can be checked with vncviewer:
vncviewer -via $(print_ip "$XENAPI_CONNECTION_URL") localhost:$(print_display "$GUEST_NAME")
EOF
    wait_for_vm_to_halt "$GUEST_NAME"

    set_reboot_on_restart "$GUEST_NAME"

    snapshot_vm "$GUEST_NAME" "$SNAPSHOT_JEOS"
fi

echo "END"
exit 0

#
# Prepare Dom0
# including installing XenAPI plugins
#

cd $THIS_DIR

# Install plugins

## Nova plugins
NOVA_ZIPBALL_URL=${NOVA_ZIPBALL_URL:-$(zip_snapshot_location $NOVA_REPO $NOVA_BRANCH)}
install_xapi_plugins_from_zipball $NOVA_ZIPBALL_URL

## Install the netwrap xapi plugin to support agent control of dom0 networking
if [[ "$ENABLED_SERVICES" =~ "q-agt" && "$Q_PLUGIN" = "openvswitch" ]]; then
    NEUTRON_ZIPBALL_URL=${NEUTRON_ZIPBALL_URL:-$(zip_snapshot_location $NEUTRON_REPO $NEUTRON_BRANCH)}
    install_xapi_plugins_from_zipball $NEUTRON_ZIPBALL_URL
fi

create_directory_for_kernels
create_directory_for_images

#
# Configure Networking
#
setup_network "$VM_BRIDGE_OR_NET_NAME"
setup_network "$MGT_BRIDGE_OR_NET_NAME"
setup_network "$PUB_BRIDGE_OR_NET_NAME"

# With neutron, one more network is required, which is internal to the
# hypervisor, and used by the VMs
if is_service_enabled neutron; then
    setup_network "$XEN_INT_BRIDGE_OR_NET_NAME"
fi

if parameter_is_specified "FLAT_NETWORK_BRIDGE"; then
    cat >&2 << EOF
ERROR: FLAT_NETWORK_BRIDGE is specified in localrc file
This is considered as an error, as its value will be derived from the
VM_BRIDGE_OR_NET_NAME variable's value.
EOF
    exit 1
fi

if ! xenapi_is_listening_on "$MGT_BRIDGE_OR_NET_NAME"; then
    cat >&2 << EOF
ERROR: XenAPI does not have an assigned IP address on the management network.
please review your XenServer network configuration / localrc file.
EOF
    exit 1
fi


# Set up ip forwarding, but skip on xcp-xapi
if [ -a /etc/sysconfig/network ]; then
    if ! grep -q "FORWARD_IPV4=YES" /etc/sysconfig/network; then
      # FIXME: This doesn't work on reboot!
      echo "FORWARD_IPV4=YES" >> /etc/sysconfig/network
    fi
fi
# Also, enable ip forwarding in rc.local, since the above trick isn't working
if ! grep -q  "echo 1 >/proc/sys/net/ipv4/ip_forward" /etc/rc.local; then
    echo "echo 1 >/proc/sys/net/ipv4/ip_forward" >> /etc/rc.local
fi
# Enable ip forwarding at runtime as well
echo 1 > /proc/sys/net/ipv4/ip_forward




#
# Create Ubuntu VM template
# and/or create VM from template
#

TNAME="devstack_template"
SNAME_PREPARED="template_prepared"
SNAME_FIRST_BOOT="before_first_boot"

templateuuid=$(xe template-list name-label="$TNAME")
if [ -z "$templateuuid" ]; then
    #
    # Install Ubuntu over network
    #

    # always update the preseed file, incase we have a newer one
    PRESEED_URL=${PRESEED_URL:-""}
    if [ -z "$PRESEED_URL" ]; then
        PRESEED_URL="${HOST_IP}/devstackubuntupreseed.cfg"
        HTTP_SERVER_LOCATION="/opt/xensource/www"
        if [ ! -e $HTTP_SERVER_LOCATION ]; then
            HTTP_SERVER_LOCATION="/var/www/html"
            mkdir -p $HTTP_SERVER_LOCATION
        fi
        cp -f $THIS_DIR/devstackubuntupreseed.cfg $HTTP_SERVER_LOCATION

        sed \
            -e "s,\(d-i mirror/http/hostname string\).*,\1 $UBUNTU_INST_HTTP_HOSTNAME,g" \
            -e "s,\(d-i mirror/http/directory string\).*,\1 $UBUNTU_INST_HTTP_DIRECTORY,g" \
            -e "s,\(d-i mirror/http/proxy string\).*,\1 $UBUNTU_INST_HTTP_PROXY,g" \
            -i "${HTTP_SERVER_LOCATION}/devstackubuntupreseed.cfg"
    fi

    # Update the template
    $THIS_DIR/scripts/install_ubuntu_template.sh $PRESEED_URL

    # create a new VM from the given template with eth0 attached to the given
    # network
    $THIS_DIR/scripts/install-os-vpx.sh \
        -t "$UBUNTU_INST_TEMPLATE_NAME" \
        -n "$UBUNTU_INST_BRIDGE_OR_NET_NAME" \
        -l "$GUEST_NAME" \
        -r "$OSDOMU_MEM_MB"

    log_info << EOF
Wait for install to finish

Progress in-VM can be checked with vncviewer:
vncviewer -via $(print_ip "$XENAPI_CONNECTION_URL") localhost:$(print_display "$GUEST_NAME")
EOF
    wait_for_vm_to_halt "$GUEST_NAME"

    set_reboot_on_restart "$GUEST_NAME"

    #
    # Prepare VM for DevStack
    #

    # Install XenServer tools, and other such things
    $THIS_DIR/prepare_guest_template.sh "$GUEST_NAME"

    # start the VM to run the prepare steps
    xe vm-start vm="$GUEST_NAME"

    log_info << EOF
Wait for prep script to finish and shutdown system

Progress in-VM can be checked with vncviewer:
vncviewer -via $(print_ip "$XENAPI_CONNECTION_URL") localhost:$(print_display "$GUEST_NAME")
EOF
    wait_for_vm_to_halt "$GUEST_NAME"

    # Make template from VM
    snuuid=$(xe vm-snapshot vm="$GUEST_NAME" new-name-label="$SNAME_PREPARED")
    xe snapshot-clone uuid=$snuuid new-name-label="$TNAME"
else
    #
    # Template already installed, create VM from template
    #
    vm_uuid=$(xe vm-install template="$TNAME" new-name-label="$GUEST_NAME")
fi

## Setup network cards
# Wipe out all
destroy_all_vifs_of "$GUEST_NAME"
# Tenant network
add_interface "$GUEST_NAME" "$VM_BRIDGE_OR_NET_NAME" "$VM_DEV_NR"
# Management network
add_interface "$GUEST_NAME" "$MGT_BRIDGE_OR_NET_NAME" "$MGT_DEV_NR"
# Public network
add_interface "$GUEST_NAME" "$PUB_BRIDGE_OR_NET_NAME" "$PUB_DEV_NR"

#
# Inject DevStack inside VM disk
#
$THIS_DIR/build_xva.sh "$GUEST_NAME"

# Attach a network interface for the integration network (so that the bridge
# is created by XenServer). This is required for Neutron. Also pass that as a
# kernel parameter for DomU
if is_service_enabled neutron; then
    add_interface "$GUEST_NAME" "$XEN_INT_BRIDGE_OR_NET_NAME" $XEN_INT_DEV_NR

    XEN_INTEGRATION_BRIDGE=$(bridge_for "$XEN_INT_BRIDGE_OR_NET_NAME")
    append_kernel_cmdline \
        "$GUEST_NAME" \
        "xen_integration_bridge=${XEN_INTEGRATION_BRIDGE}"
fi

FLAT_NETWORK_BRIDGE=$(bridge_for "$VM_BRIDGE_OR_NET_NAME")
append_kernel_cmdline "$GUEST_NAME" "flat_network_bridge=${FLAT_NETWORK_BRIDGE}"

# Add a separate xvdb, if it was requested
if [[ "0" != "$XEN_XVDB_SIZE_GB" ]]; then
    vm=$(xe vm-list name-label="$GUEST_NAME" --minimal)

    # Add a new disk
    localsr=$(get_local_sr)
    extra_vdi=$(xe vdi-create \
        name-label=xvdb-added-by-devstack \
        virtual-size="${XEN_XVDB_SIZE_GB}GiB" \
        sr-uuid=$localsr type=user)
    xe vbd-create vm-uuid=$vm vdi-uuid=$extra_vdi device=1
fi

# create a snapshot before the first boot
# to allow a quick re-run with the same settings
xe vm-snapshot vm="$GUEST_NAME" new-name-label="$SNAME_FIRST_BOOT"

#
# Run DevStack VM
#
xe vm-start vm="$GUEST_NAME"

function ssh_no_check() {
    ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no "$@"
}

# Get hold of the Management IP of OpenStack VM
OS_VM_MANAGEMENT_ADDRESS=$MGT_IP
if [ $OS_VM_MANAGEMENT_ADDRESS == "dhcp" ]; then
    OS_VM_MANAGEMENT_ADDRESS=$(find_ip_by_name $GUEST_NAME $MGT_DEV_NR)
fi

# Get hold of the Service IP of OpenStack VM
if [ $HOST_IP_IFACE == "eth${MGT_DEV_NR}" ]; then
    OS_VM_SERVICES_ADDRESS=$MGT_IP
    if [ $MGT_IP == "dhcp" ]; then
        OS_VM_SERVICES_ADDRESS=$(find_ip_by_name $GUEST_NAME $MGT_DEV_NR)
    fi
else
    OS_VM_SERVICES_ADDRESS=$PUB_IP
    if [ $PUB_IP == "dhcp" ]; then
        OS_VM_SERVICES_ADDRESS=$(find_ip_by_name $GUEST_NAME $PUB_DEV_NR)
    fi
fi

# If we have copied our ssh credentials, use ssh to monitor while the installation runs
WAIT_TILL_LAUNCH=${WAIT_TILL_LAUNCH:-1}
COPYENV=${COPYENV:-1}
if [ "$WAIT_TILL_LAUNCH" = "1" ]  && [ -e ~/.ssh/id_rsa.pub  ] && [ "$COPYENV" = "1" ]; then
    set +x

    echo "VM Launched - Waiting for startup script"
    # wait for log to appear
    while ! ssh_no_check -q stack@$OS_VM_MANAGEMENT_ADDRESS "[ -e run.sh.log ]"; do
        sleep 10
    done
    echo -n "Running"
    while [ `ssh_no_check -q stack@$OS_VM_MANAGEMENT_ADDRESS pgrep -c run.sh` -ge 1 ]
    do
        sleep 10
        echo -n "."
    done
    echo "done!"
    set -x

    # output the run.sh.log
    ssh_no_check -q stack@$OS_VM_MANAGEMENT_ADDRESS 'cat run.sh.log'

    # Fail if the expected text is not found
    ssh_no_check -q stack@$OS_VM_MANAGEMENT_ADDRESS 'cat run.sh.log' | grep -q 'stack.sh completed in'

    log_info << EOF
################################################################################

All Finished!
You can visit the OpenStack Dashboard
at http://$OS_VM_SERVICES_ADDRESS, and contact other services at the usual ports.
EOF
else
    log_info << EOF
################################################################################

All Finished!
Now, you can monitor the progress of the stack.sh installation by
tailing /opt/stack/run.sh.log from within your domU.

ssh into your domU now: 'ssh stack@$OS_VM_MANAGEMENT_ADDRESS' using your password
and then do: 'tail -f /opt/stack/run.sh.log'

When the script completes, you can then visit the OpenStack Dashboard
at http://$OS_VM_SERVICES_ADDRESS, and contact other services at the usual ports.
EOF
fi
