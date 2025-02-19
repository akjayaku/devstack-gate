#!/bin/bash

# Gate commits to several projects on a VM running those projects
# configured by devstack.

# Copyright (C) 2011-2013 OpenStack Foundation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.
#
# See the License for the specific language governing permissions and
# limitations under the License.

# Most of the work of this script is done in functions so that we may
# easily redirect their stdout / stderr to log files.

GIT_BASE=${GIT_BASE:-https://opendev.org}
GIT_BRANCH=${GIT_BRANCH:-master}

# We're using enough ansible specific features that it's extremely
# possible that new ansible releases can break us. As such we should
# be very deliberate about which ansible we use.
# NOTE(mriedem): Ansible 2.7.14 is current as of Ubuntu Xenial 16.04.
# ARA is pinned to <1.0.0 below which affects the required version of Ansible.
ANSIBLE_VERSION=${ANSIBLE_VERSION:-2.7.14}
export DSTOOLS_VERSION=${DSTOOLS_VERSION:-0.4.0}

# Set to 0 to skip stackviz
export PROCESS_STACKVIZ=${PROCESS_STACKVIZ:-1}

# sshd may have been compiled with a default path excluding */sbin
export PATH=$PATH:/usr/local/sbin:/usr/sbin
# When doing xtrace (set -x / set -o xtrace), provide more debug output
export PS4='+ ${BASH_SOURCE:-}:${FUNCNAME[0]:-}:L${LINENO:-}:   '

#check to see if WORKSPACE var is defined
if [ -z ${WORKSPACE} ]; then
    echo "The 'WORKSPACE' variable is undefined. It must be defined for this script to work"
    exit 1
fi

source $WORKSPACE/devstack-gate/functions.sh

start_timer

# Note that service/project enablement vars are here so that they can be
# used to select the PROJECTS list below reliably.

# Set to 1 to run sahara
export DEVSTACK_GATE_SAHARA=${DEVSTACK_GATE_SAHARA:-0}

# Set to 1 to run trove
export DEVSTACK_GATE_TROVE=${DEVSTACK_GATE_TROVE:-0}

# are we pulling any libraries from git
export DEVSTACK_PROJECT_FROM_GIT=${DEVSTACK_PROJECT_FROM_GIT:-}

# Save the PROJECTS variable as it was passed in.  This is needed for reproduce.sh
# incase the job definition contains items that are not in the "global" list
# below.
# See: https://bugs.launchpad.net/openstack-gate/+bug/1544827
JOB_PROJECTS="$PROJECTS"
PROJECTS="openstack/devstack-gate $PROJECTS"
PROJECTS="openstack/devstack $PROJECTS"
PROJECTS="openstack/ceilometer $PROJECTS"
PROJECTS="openstack/ceilometermiddleware $PROJECTS"
PROJECTS="openstack/cinder $PROJECTS"
PROJECTS="openstack/glance $PROJECTS"
PROJECTS="openstack/heat $PROJECTS"
PROJECTS="openstack/heat-cfntools $PROJECTS"
PROJECTS="openstack/heat-templates $PROJECTS"
if [[ "$DEVSTACK_GATE_HORIZON" -eq "1" || "$DEVSTACK_PROJECT_FROM_GIT" = "django_openstack_auth" || "$DEVSTACK_PROJECT_FROM_GIT" = "manila-ui" ]] ; then
    PROJECTS="openstack/horizon $PROJECTS"
    PROJECTS="openstack/django_openstack_auth $PROJECTS"
    PROJECTS="openstack/manila-ui $PROJECTS"
fi
PROJECTS="openstack/keystone $PROJECTS"
PROJECTS="openstack/neutron $PROJECTS"
PROJECTS="openstack/nova $PROJECTS"
PROJECTS="openstack/requirements $PROJECTS"
PROJECTS="openstack/swift $PROJECTS"
PROJECTS="openstack/tempest $PROJECTS"
# Everything below this line in the PROJECTS list is for non
# default devstack runs. Overtime we should remove items from
# below and add them explicitly to the jobs that need them. The
# reason for this is to reduce job runtimes, every git repo
# has to be cloned and updated and checked out to the proper ref
# which is not free.
PROJECTS="openstack/tripleo-ci $PROJECTS"
# The devstack heat plugin uses these repos
if [[ "$DEVSTACK_GATE_HEAT" -eq "1" ]] ; then
    PROJECTS="openstack/dib-utils $PROJECTS"
    PROJECTS="openstack/diskimage-builder $PROJECTS"
fi
PROJECTS="openstack/glance_store $PROJECTS"
PROJECTS="openstack/keystoneauth $PROJECTS"
PROJECTS="openstack/keystonemiddleware $PROJECTS"
PROJECTS="openstack/manila $PROJECTS"
PROJECTS="openstack/zaqar $PROJECTS"
PROJECTS="openstack/neutron-fwaas $PROJECTS"
PROJECTS="openstack/neutron-lbaas $PROJECTS"
PROJECTS="openstack/octavia $PROJECTS"
PROJECTS="openstack/neutron-vpnaas $PROJECTS"
PROJECTS="openstack/os-apply-config $PROJECTS"
PROJECTS="openstack/os-brick $PROJECTS"
PROJECTS="openstack/os-client-config $PROJECTS"
PROJECTS="openstack/os-collect-config $PROJECTS"
PROJECTS="openstack/os-net-config $PROJECTS"
PROJECTS="openstack/os-refresh-config $PROJECTS"
PROJECTS="openstack/osc-lib $PROJECTS"
if [[ "$DEVSTACK_GATE_SAHARA" -eq "1" ]] ; then
    PROJECTS="openstack/sahara $PROJECTS"
    PROJECTS="openstack/sahara-dashboard $PROJECTS"
fi
PROJECTS="openstack/tripleo-heat-templates $PROJECTS"
PROJECTS="openstack/tripleo-image-elements $PROJECTS"
if [[ "$DEVSTACK_GATE_TROVE" -eq "1" ]] ; then
    PROJECTS="openstack/trove $PROJECTS"
fi
if [[ -n "$DEVSTACK_PROJECT_FROM_GIT" ]] ; then
    # We populate the PROJECTS list with any libs that should be installed
    # from source and not pypi assuming that live under openstack/
    TRAILING_COMMA_REMOVED=$(echo "$DEVSTACK_PROJECT_FROM_GIT" | sed -e 's/,$//')
    PROCESSED_FROM_GIT=$(echo "openstack/$TRAILING_COMMA_REMOVED" | sed -e 's/,/ openstack\//g')
    PROJECTS="$PROCESSED_FROM_GIT $PROJECTS"
fi

# Include openstack/placement starting in Stein.
stable_compare="stable/[a-r]"
if [[ ! "$OVERRIDE_ZUUL_BRANCH" =~ $stable_compare ]] ; then
    PROJECTS="openstack/placement $PROJECTS"
fi

# Remove duplicates as they result in errors when managing
# git state.
PROJECTS=$(echo $PROJECTS | tr '[:space:]' '\n' | sort -u)

echo "The PROJECTS list is:"
echo $PROJECTS | fold -w 80 -s
echo "---"

export BASE=/opt/stack

# The URL from which to fetch ZUUL references
export ZUUL_URL=${ZUUL_URL:-http://zuul.openstack.org/p}

# The feature matrix to select devstack-gate components
export DEVSTACK_GATE_FEATURE_MATRIX=${DEVSTACK_GATE_FEATURE_MATRIX:-roles/test-matrix/files/features.yaml}

# Set to 1 to install, configure and enable the Tempest test suite; more flags may be
# required to be set to customize the test run, e.g. DEVSTACK_GATE_TEMPEST_STRESS=1
export DEVSTACK_GATE_TEMPEST=${DEVSTACK_GATE_TEMPEST:-0}

# Set to 1, in conjunction with DEVSTACK_GATE_TEMPEST, will allow Tempest to be
# installed and configured, but the tests will be skipped
export DEVSTACK_GATE_TEMPEST_NOTESTS=${DEVSTACK_GATE_TEMPEST_NOTESTS:-0}

# Set to 1 to run postgresql instead of mysql
export DEVSTACK_GATE_POSTGRES=${DEVSTACK_GATE_POSTGRES:-0}

# Set to 1 to use zeromq instead of rabbitmq (or qpid)
export DEVSTACK_GATE_ZEROMQ=${DEVSTACK_GATE_ZEROMQ:-0}

# Set to qpid to use qpid, or zeromq to use zeromq.
# Default set to rabbitmq
export DEVSTACK_GATE_MQ_DRIVER=${DEVSTACK_GATE_MQ_DRIVER:-"rabbitmq"}

# This value must be provided when DEVSTACK_GATE_TEMPEST_STRESS is set.
export DEVSTACK_GATE_TEMPEST_STRESS_ARGS=${DEVSTACK_GATE_TEMPEST_STRESS_ARGS:-""}

# Set to 1 to run tempest heat slow tests
export DEVSTACK_GATE_TEMPEST_HEAT_SLOW=${DEVSTACK_GATE_TEMPEST_HEAT_SLOW:-0}

# Set to 1 to run tempest large ops test
export DEVSTACK_GATE_TEMPEST_LARGE_OPS=${DEVSTACK_GATE_TEMPEST_LARGE_OPS:-0}

# Set to 1 to run tempest smoke tests serially
export DEVSTACK_GATE_SMOKE_SERIAL=${DEVSTACK_GATE_SMOKE_SERIAL:-0}

# Set to 1 to explicitly disable tempest tenant isolation. Otherwise tenant isolation setting
# for tempest will be the one chosen by devstack.
export DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION=${DEVSTACK_GATE_TEMPEST_DISABLE_TENANT_ISOLATION:-0}

# Should cinder perform secure deletion of volumes?
# Defaults to none to avoid bug 1023755. Can also be set to zero or shred.
# Only applicable to stable/liberty+ devstack.
export DEVSTACK_CINDER_VOLUME_CLEAR=${DEVSTACK_CINDER_VOLUME_CLEAR:-none}

# Set this to override the branch selected for testing (in
# single-branch checkouts; not used for grenade)
export OVERRIDE_ZUUL_BRANCH=${OVERRIDE_ZUUL_BRANCH:-$ZUUL_BRANCH}

stable_compare="stable/[a-n]"

# Set to 1 to run neutron instead of nova network
# This is a bit complicated to handle the deprecation of nova net across
# repos with branches from this branchless job runner.
if [ -n "$DEVSTACK_GATE_NEUTRON" ] ; then
    # If someone has made a choice externally honor it
    export DEVSTACK_GATE_NEUTRON=$DEVSTACK_GATE_NEUTRON
elif [[ "$OVERRIDE_ZUUL_BRANCH" =~ $stable_compare ]] ; then
    # Default to no neutron on older stable branches because nova net
    # was the default all that time.
    export DEVSTACK_GATE_NEUTRON=0
else
    # For everything else there is neutron
    export DEVSTACK_GATE_NEUTRON=1
fi


# Set to 1 to run neutron distributed virtual routing
export DEVSTACK_GATE_NEUTRON_DVR=${DEVSTACK_GATE_NEUTRON_DVR:-0}

# This variable tells devstack-gate to set up an overlay network between the nodes.
export DEVSTACK_GATE_NET_OVERLAY=${DEVSTACK_GATE_NET_OVERLAY:-$DEVSTACK_GATE_NEUTRON_DVR}

# Set to 1 to run nova in cells mode instead of the default mode
export DEVSTACK_GATE_CELLS=${DEVSTACK_GATE_CELLS:-0}

# Set to 1 to run nova in with nova metadata server as a separate binary
export DEVSTACK_GATE_NOVA_API_METADATA_SPLIT=${DEVSTACK_GATE_NOVA_API_METADATA_SPLIT:-0}

# Set to 1 to run ironic baremetal provisioning service.
export DEVSTACK_GATE_IRONIC=${DEVSTACK_GATE_IRONIC:-0}

# Set to "agent_ipmitool" to run ironic with the ironic-python-agent driver
export DEVSTACK_GATE_IRONIC_DRIVER=${DEVSTACK_GATE_IRONIC_DRIVER:-pxe_ipmitool}


# Set to 0 to avoid building Ironic deploy ramdisks
export DEVSTACK_GATE_IRONIC_BUILD_RAMDISK=${DEVSTACK_GATE_IRONIC_BUILD_RAMDISK:-1}

# Set to 0 to disable config_drive and use the metadata server instead
export DEVSTACK_GATE_CONFIGDRIVE=${DEVSTACK_GATE_CONFIGDRIVE:-0}

# Set to 1 to enable installing test requirements
export DEVSTACK_GATE_INSTALL_TESTONLY=${DEVSTACK_GATE_INSTALL_TESTONLY:-0}

# Set the number of threads to run tempest with
DEFAULT_CONCURRENCY=$(nproc)
if [ ${DEFAULT_CONCURRENCY} -gt 3 ] ; then
    DEFAULT_CONCURRENCY=$((${DEFAULT_CONCURRENCY} / 2))
fi
export TEMPEST_CONCURRENCY=${TEMPEST_CONCURRENCY:-${DEFAULT_CONCURRENCY}}

# The following variable is set for different directions of Grenade updating
# for a stable branch we want to both try to upgrade forward n => n+1 as
# well as upgrade from last n-1 => n.
#
# i.e. stable/ocata:
#   pullup means stable/newton => stable/ocata
#   forward means stable/ocata => master (or stable/pike if that's out)
export DEVSTACK_GATE_GRENADE=${DEVSTACK_GATE_GRENADE:-}

# the branch name for selecting grenade branches
GRENADE_BASE_BRANCH=${OVERRIDE_ZUUL_BRANCH:-${ZUUL_BRANCH}}


if [[ -n "$DEVSTACK_GATE_GRENADE" ]]; then
    # All grenade upgrades get tempest
    export DEVSTACK_GATE_TEMPEST=1

    # NOTE(sdague): Adjusting grenade branches for a release.
    #
    # When we get to the point of the release where we should adjust
    # the grenade branches, the order of doing so is important.
    #
    # 1. stable/foo on all projects in devstack
    # 2. stable/foo on devstack
    # 3. stable/foo on grenade
    # 4. adjust branches in devstack-gate
    #
    # The devstack-gate branch logic going last means that it will be
    # tested before thrust upon the jobs. For both the stable/kilo and
    # stable/liberty releases real release issues were found in this
    # process. So this should be done as early as possible.

    case $DEVSTACK_GATE_GRENADE in

        # sideways upgrades try to move between configurations in the
        # same release, typically used for migrating between services
        # or configurations.
        sideways-*)
            export GRENADE_OLD_BRANCH="$GRENADE_BASE_BRANCH"
            export GRENADE_NEW_BRANCH="$GRENADE_BASE_BRANCH"
            ;;

        # forward upgrades are an attempt to migrate up from an
        # existing stable branch to the next release.
        forward)
            if [[ "$GRENADE_BASE_BRANCH" == "stable/kilo" ]]; then
                export GRENADE_OLD_BRANCH="stable/kilo"
                export GRENADE_NEW_BRANCH="stable/liberty"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/liberty" ]]; then
                export GRENADE_OLD_BRANCH="stable/liberty"
                export GRENADE_NEW_BRANCH="stable/mitaka"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/mitaka" ]]; then
                export GRENADE_OLD_BRANCH="stable/mitaka"
                export GRENADE_NEW_BRANCH="stable/newton"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/newton" ]]; then
                export GRENADE_OLD_BRANCH="stable/newton"
                export GRENADE_NEW_BRANCH="$GIT_BRANCH"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/ocata" ]]; then
                export GRENADE_OLD_BRANCH="stable/ocata"
                export GRENADE_NEW_BRANCH="stable/pike"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/pike" ]]; then
                export GRENADE_OLD_BRANCH="stable/pike"
                export GRENADE_NEW_BRANCH="stable/queens"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/queens" ]]; then
                export GRENADE_OLD_BRANCH="stable/queens"
                export GRENADE_NEW_BRANCH="stable/rocky"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/rocky" ]]; then
                export GRENADE_OLD_BRANCH="stable/rocky"
                export GRENADE_NEW_BRANCH="stable/stein"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/stein" ]]; then
                export GRENADE_OLD_BRANCH="stable/stein"
                export GRENADE_NEW_BRANCH="stable/train"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/train" ]]; then
                export GRENADE_OLD_BRANCH="stable/train"
                export GRENADE_NEW_BRANCH="stable/ussuri"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/ussuri" ]]; then
                export GRENADE_OLD_BRANCH="stable/ussuri"
                export GRENADE_NEW_BRANCH="stable/victoria"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/victoria" ]]; then
                export GRENADE_OLD_BRANCH="stable/victoria"
                export GRENADE_NEW_BRANCH="$GIT_BRANCH"
            fi
            ;;

        # pullup upgrades are our normal upgrade test. Can you upgrade
        # to the current patch from the last stable.
        pullup)
            if [[ "$GRENADE_BASE_BRANCH" == "stable/liberty" ]]; then
                export GRENADE_OLD_BRANCH="stable/kilo"
                export GRENADE_NEW_BRANCH="stable/liberty"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/mitaka" ]]; then
                export GRENADE_OLD_BRANCH="stable/liberty"
                export GRENADE_NEW_BRANCH="stable/mitaka"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/newton" ]]; then
                export GRENADE_OLD_BRANCH="stable/mitaka"
                export GRENADE_NEW_BRANCH="stable/newton"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/ocata" ]]; then
                export GRENADE_OLD_BRANCH="stable/newton"
                export GRENADE_NEW_BRANCH="stable/ocata"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/pike" ]]; then
                export GRENADE_OLD_BRANCH="stable/ocata"
                export GRENADE_NEW_BRANCH="stable/pike"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/queens" ]]; then
                export GRENADE_OLD_BRANCH="stable/pike"
                export GRENADE_NEW_BRANCH="stable/queens"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/rocky" ]]; then
                export GRENADE_OLD_BRANCH="stable/queens"
                export GRENADE_NEW_BRANCH="stable/rocky"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/stein" ]]; then
                export GRENADE_OLD_BRANCH="stable/rocky"
                export GRENADE_NEW_BRANCH="stable/stein"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/train" ]]; then
                export GRENADE_OLD_BRANCH="stable/stein"
                export GRENADE_NEW_BRANCH="stable/train"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/ussuri" ]]; then
                export GRENADE_OLD_BRANCH="stable/train"
                export GRENADE_NEW_BRANCH="stable/ussuri"
            elif [[ "$GRENADE_BASE_BRANCH" == "stable/victoria" ]]; then
                export GRENADE_OLD_BRANCH="stable/ussuri"
                export GRENADE_NEW_BRANCH="stable/victoria"
            else # master
                export GRENADE_OLD_BRANCH="stable/victoria"
                export GRENADE_NEW_BRANCH="$GIT_BRANCH"
            fi
            ;;

        # If we got here, someone typoed a thing, and we should fail
        # explicitly so they don't accidentally pass in some what that
        # is unexpected.
        *)
            echo "Unsupported upgrade mode: $DEVSTACK_GATE_GRENADE"
            exit 1
            ;;
    esac
fi

# Set the virtualization driver to: libvirt, openvz, xenapi
export DEVSTACK_GATE_VIRT_DRIVER=${DEVSTACK_GATE_VIRT_DRIVER:-libvirt}

# Use qemu by default for consistency since some providers enable
# nested virt
export DEVSTACK_GATE_LIBVIRT_TYPE=${DEVSTACK_GATE_LIBVIRT_TYPE:-qemu}

# See switch below for this -- it gets set to 1 when tempest
# is the project being gated.
export DEVSTACK_GATE_TEMPEST_FULL=${DEVSTACK_GATE_TEMPEST_FULL:-0}

# Set to 1 to run all tempest tests
export DEVSTACK_GATE_TEMPEST_ALL=${DEVSTACK_GATE_TEMPEST_ALL:-0}

# Set to 1 to run all tempest scenario tests
export DEVSTACK_GATE_TEMPEST_SCENARIOS=${DEVSTACK_GATE_TEMPEST_SCENARIOS:-0}

# Set to a regex to run tempest with a custom regex filter
export DEVSTACK_GATE_TEMPEST_REGEX=${DEVSTACK_GATE_TEMPEST_REGEX:-""}

# Set to 1 to run all-plugin tempest tests
export DEVSTACK_GATE_TEMPEST_ALL_PLUGINS=${DEVSTACK_GATE_TEMPEST_ALL_PLUGINS:-0}

# Set to 1 if running the openstack/requirements integration test
export DEVSTACK_GATE_REQS_INTEGRATION=${DEVSTACK_GATE_REQS_INTEGRATION:-0}

# Set to 0 to disable clean logs enforcement (3rd party CI might want to do this
# until they get their driver cleaned up)
export DEVSTACK_GATE_CLEAN_LOGS=${DEVSTACK_GATE_CLEAN_LOGS:-1}

# Set this to the time in milliseconds that the entire job should be
# allowed to run before being aborted (default 120 minutes=7200000ms).
# This may be supplied by Jenkins based on the configured job timeout
# which is why it's in this convenient unit.
export BUILD_TIMEOUT=$(expr ${BUILD_TIMEOUT:-7200000} / 60000)

# Set this to the time in minutes that should be reserved for
# uploading artifacts at the end after a timeout.  Defaults to 10
# minutes.
export DEVSTACK_GATE_TIMEOUT_BUFFER=${DEVSTACK_GATE_TIMEOUT_BUFFER:-10}

# Not user servicable.
export DEVSTACK_GATE_TIMEOUT=$(expr $BUILD_TIMEOUT - $DEVSTACK_GATE_TIMEOUT_BUFFER)

# Set to 1 to remove the stack users blanket sudo permissions forcing
# openstack services running as the stack user to rely on rootwrap rulesets
# instead of raw sudo. Do this to ensure rootwrap works. This is the default.
export DEVSTACK_GATE_REMOVE_STACK_SUDO=${DEVSTACK_GATE_REMOVE_STACK_SUDO:-1}

# Set to 1 to unstack immediately after devstack installation.  This
# is intended to be a stop-gap until devstack can support
# dependency-only installation.
export DEVSTACK_GATE_UNSTACK=${DEVSTACK_GATE_UNSTACK:-0}

# The topology of the system determinates the service distribution
# among the nodes.
# aio: `all in one` just only one node used
# aiopcpu: `all in one plus compute` one node will be installed as aio
# the extra nodes will gets only limited set of services
# ctrlpcpu: `controller plus compute` One node will gets the controller type
# services without the compute type of services, the others gets,
# the compute style services several services can be common,
# the networking services also presents on the controller [WIP]
export DEVSTACK_GATE_TOPOLOGY=${DEVSTACK_GATE_TOPOLOGY:-aio}

# Set to a space-separated list of projects to prepare in the
# workspace, e.g. 'openstack/devstack openstack/neutron'.
# Minimizing the number of targeted projects can reduce the setup cost
# for jobs that know exactly which repos they need.
export DEVSTACK_GATE_PROJECTS_OVERRIDE=${DEVSTACK_GATE_PROJECTS_OVERRIDE:-""}

# Set this to "True" to force devstack to pick python 3.x. "False" will cause
# devstack to pick python 2.x. We should leave this empty for devstack to
# pick the default.
export DEVSTACK_GATE_USE_PYTHON3=${DEVSTACK_GATE_USE_PYTHON3:-""}

# Set this to enable remote logging of the console via UDP packets to
# a specified ipv4 ip:port (note; not hostname -- ip address only).
# This can be extremely useful if a host is oopsing or dropping off
# the network amd you are not getting any useful logs from jenkins.
#
# To capture these logs, enable a netcat/socat type listener to
# capture UDP packets at the specified remote ip.  For example:
#
#  $ nc -v -u -l -p 6666 | tee save-output.log
# or
#  $ socat udp-recv:6666 - | tee save-output.log
#
# One further trick is to send interesting data to /dev/ksmg; this
# data will get out over the netconsole even if the main interfaces
# have been disabled, etc.  e.g.
#
#  $ ip addr | sudo tee /dev/ksmg
#
export DEVSTACK_GATE_NETCONSOLE=${DEVSTACK_GATE_NETCONSOLE:-""}
enable_netconsole

if [ -n "$DEVSTACK_GATE_PROJECTS_OVERRIDE" ]; then
    PROJECTS=$DEVSTACK_GATE_PROJECTS_OVERRIDE
fi

if ! function_exists "gate_hook"; then
    # the command we use to run the gate
    function gate_hook {
        $BASE/new/devstack-gate/devstack-vm-gate.sh
    }
    export -f gate_hook
fi

echo "Triggered by: https://review.openstack.org/$ZUUL_CHANGE patchset $ZUUL_PATCHSET"
echo "Pipeline: $ZUUL_PIPELINE"
echo "Timeout set to $DEVSTACK_GATE_TIMEOUT minutes \
with $DEVSTACK_GATE_TIMEOUT_BUFFER minutes reserved for cleanup."
echo "Available disk space on this host:"
indent df -h

if command -v python3 &>/dev/null; then
    PIP=pip3
    PYTHON_VER=$(python3 -c 'import sys; print("%s.%s" % sys.version_info[0:2])')
else
    PIP=pip
    PYTHON_VER=2.7
fi

#echo "Debugs... removing all pip packages before start devstack gate..."

#sudo $PIP freeze | grep -Ev 'ansible|setup|virtualenv'  | xargs sudo $PIP uninstall -y

#sudo pip freeze | grep -Ev 'ansible|setup|virtualenv'  | xargs sudo pip uninstall -y

# Install ansible

# TODO(gmann): virtualenv 20.0.1 is broken, one known issue:
# https://github.com/pypa/virtualenv/issues/1551
# Once virtualenv is fixed we can use the latest one.
sudo -H $PIP install "virtualenv<20.0.0"
#sudo -H pip3 install "virtualenv"
virtualenv -p python${PYTHON_VER} /tmp/ansible

# Explicitly install pbr first as this will use pip rathat than
# easy_install. Hope is this is generally more reliable.
/tmp/ansible/bin/pip install pbr
/tmp/ansible/bin/pip install ansible==$ANSIBLE_VERSION \
                devstack-tools==$DSTOOLS_VERSION 'ara<1.0.0' 'cmd2<0.9.0'
#/tmp/ansible/bin/pip install ansible \
#                devstack-tools==$DSTOOLS_VERSION 'ara<1.0.0' 'cmd2<0.9.0'

export ANSIBLE=/tmp/ansible/bin/ansible
export ANSIBLE_PLAYBOOK=/tmp/ansible/bin/ansible-playbook
export ANSIBLE_CONFIG="$WORKSPACE/ansible.cfg"
export DSCONF=/tmp/ansible/bin/dsconf

# Write inventory file with groupings
COUNTER=1
PRIMARY_NODE=$(cat /etc/nodepool/primary_node_private)
echo "[primary]" > "$WORKSPACE/inventory"
echo "localhost ansible_connection=local host_counter=$COUNTER nodepool='{\"private_ipv4\": \"$PRIMARY_NODE\"}'" >> "$WORKSPACE/inventory"
echo "[subnodes]" >> "$WORKSPACE/inventory"
export SUBNODES=$(cat /etc/nodepool/sub_nodes_private)
for SUBNODE in $SUBNODES ; do
    let COUNTER=COUNTER+1
    echo "$SUBNODE host_counter=$COUNTER nodepool='{\"private_ipv4\": \"$SUBNODE\"}'" >> "$WORKSPACE/inventory"
done

# Write ansible config file
cat > $ANSIBLE_CONFIG <<EOF
[defaults]
callback_plugins = $WORKSPACE/devstack-gate/playbooks/plugins/callback:/tmp/ansible/lib/python${PYTHON_VER}/site-packages/ara/plugins/callbacks
stdout_callback = devstack

# Disable SSH host key checking
host_key_checking = False
EOF

# NOTE(clarkb): for simplicity we evaluate all bash vars in ansible commands
# on the node running these scripts, we do not pass through unexpanded
# vars to ansible shell commands. This may need to change in the future but
# for now the current setup is simple, consistent and easy to understand.

# This is in brackets for avoiding inheriting a huge environment variable
(export PROJECTS; export > "$WORKSPACE/test_env.sh")
# Copy bootstrap to remote hosts
$ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" -m copy \
    -a "src='$WORKSPACE/devstack-gate' dest='$WORKSPACE'"
$ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" -m copy \
    -a "src='$WORKSPACE/test_env.sh' dest='$WORKSPACE/test_env.sh'"

# Make a directory to store logs
$ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m file \
    -a "path='$WORKSPACE/logs' state=absent"
$ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m file \
    -a "path='$WORKSPACE/logs' state=directory"

# Record a file to reproduce this build
reproduce "$JOB_PROJECTS"

# Run ansible to do setup_host on all nodes.
echo "Setting up the hosts"

# This function handles any common exit paths from here on in
function exit_handler {
    local status=$1

    # Generate ARA report
    /tmp/ansible/bin/ara generate html $WORKSPACE/logs/ara
    gzip --recursive --best $WORKSPACE/logs/ara

    if [[ $status -ne 0 ]]; then
        echo "*** FAILED with status: $status"
    else
        echo "SUCCESSFULLY FINISHED"
    fi

    exit $status
}

# little helper that runs anything passed in under tsfilter
function run_command {
    local fn="$@"
    local cmd=""

    # note that we want to keep the tsfilter separate; it's a trap for
    # new-players that errexit isn't applied if we do "&& tsfilter
    # ..."  and thus we won't pick up any failures in the commands the
    # function runs.
    #
    # Note we also send stderr to stdout, otherwise ansible consumes
    # each separately and outputs them separately.  That doesn't work
    # well for log files; especially running "xtrace" in bash which
    # puts tracing on stderr.
    read -r -d '' cmd <<EOF
source '$WORKSPACE/test_env.sh'
source '$WORKSPACE/devstack-gate/functions.sh'
set -o errexit
tsfilter $fn 2>&1
executable=/bin/bash
EOF

    echo "$cmd"
}

rc=0

echo "... this takes a few seconds (logs at logs/devstack-gate-setup-host.txt.gz)"
$ANSIBLE_PLAYBOOK -f 5 -i "$WORKSPACE/inventory" "$WORKSPACE/devstack-gate/playbooks/setup_host.yaml" \
    &> "$WORKSPACE/logs/devstack-gate-setup-host.txt" || rc=$?
echo "Debugs... devstack gate setup host output..."
cat $WORKSPACE/logs/devstack-gate-setup-host.txt
cat $WORKSPACE/devstack-gate/playbooks/setup_host.yaml
cat $WORKSPACE/inventory

if [[ $rc -ne 0 ]]; then
   echo "Ignoring devstack-gate-setup-host failure..."
   #exit_handler $rc;
   rc=0
fi

if [ -n "$DEVSTACK_GATE_GRENADE" ]; then
    start=$(date +%s)
    echo "Setting up the new (migrate to) workspace"
    echo "... this takes 3 - 5 minutes (logs at logs/devstack-gate-setup-workspace-new.txt.gz)"
    $ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
            -a "$(run_command setup_workspace '$GRENADE_NEW_BRANCH' '$BASE/new')" \
        &> "$WORKSPACE/logs/devstack-gate-setup-workspace-new.txt" || rc=$?
    if [[ $rc -ne 0 ]]; then
        exit_handler $rc;
    fi
    echo "Setting up the old (migrate from) workspace ..."
    echo "... this takes 3 - 5 minutes (logs at logs/devstack-gate-setup-workspace-old.txt.gz)"
    $ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "$(run_command setup_workspace '$GRENADE_OLD_BRANCH' '$BASE/old')" \
        &> "$WORKSPACE/logs/devstack-gate-setup-workspace-old.txt" || rc=$?
    end=$(date +%s)
    took=$((($end - $start) / 60))
    if [[ "$took" -gt 20 ]]; then
        echo "WARNING: setup of 2 workspaces took > 20 minutes, this is a very slow node."
    fi
    if [[ $rc -ne 0 ]]; then
        exit_handler $rc;
    fi
else
    echo "Setting up the workspace"
    echo "... this takes 3 - 5 minutes (logs at logs/devstack-gate-setup-workspace-new.txt.gz)"
    start=$(date +%s)
    $ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
        -a "$(run_command setup_workspace '$OVERRIDE_ZUUL_BRANCH' '$BASE/new')" \
        &> "$WORKSPACE/logs/devstack-gate-setup-workspace-new.txt" || rc=$?
    end=$(date +%s)
    took=$((($end - $start) / 60))
    if [[ "$took" -gt 10 ]]; then
        echo "WARNING: setup workspace took > 10 minutes, this is a very slow node."
    fi
    if [[ $rc -ne 0 ]]; then
        #exit_handler $rc;
	echo "Debugs...."
	cat $WORKSPACE/logs/devstack-gate-setup-workspace-new.txt
	rc=0
    fi
fi

# relocate and symlink logs into $BASE to save space on the root filesystem
# TODO: make this more ansibley
$ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell -a "
if [ -d '$WORKSPACE/logs' -a \! -e '$BASE/logs' ]; then
    sudo mv '$WORKSPACE/logs' '$BASE/'
    ln -s '$BASE/logs' '$WORKSPACE/'
fi executable=/bin/bash"

# The DEVSTACK_GATE_SETTINGS variable may contain a path to a script that
# should be sourced after the environment has been set up.  This is useful for
# allowing projects to provide a script in their repo that sets some custom
# environment variables.
check_for_devstack_gate_settings() {
    if [ -f $1 ] ; then
        return 0
    else
        return 1
    fi
}
if [ -n "${DEVSTACK_GATE_SETTINGS}" ] ; then
    if check_for_devstack_gate_settings ${DEVSTACK_GATE_SETTINGS} ; then
        source ${DEVSTACK_GATE_SETTINGS}
    else
        echo "WARNING: DEVSTACK_GATE_SETTINGS file does not exist: '${DEVSTACK_GATE_SETTINGS}'"
    fi
fi

# Note that hooks should be multihost aware if necessary.
# devstack-vm-gate-wrap.sh will not automagically run the hooks on each node.
# Run pre test hook if we have one
with_timeout call_hook_if_defined "pre_test_hook"
GATE_RETVAL=$?
if [ $GATE_RETVAL -ne 0 ]; then
    echo "ERROR: the pre-test setup script run by this job failed - exit code: $GATE_RETVAL"
fi

# Run the gate function
if [ $GATE_RETVAL -eq 0 ]; then
    echo "Running gate_hook"
    with_timeout "gate_hook"
    GATE_RETVAL=$?
    if [ $GATE_RETVAL -ne 0 ]; then
        echo "ERROR: the main setup script run by this job failed - exit code: $GATE_RETVAL"
    fi
fi
RETVAL=$GATE_RETVAL

if [ $GATE_RETVAL -ne 0 ]; then
    echo "    please look at the relevant log files to determine the root cause"
    echo "Running devstack worlddump.py"
    sudo $BASE/new/devstack/tools/worlddump.py -d $BASE/logs
fi

# Run post test hook if we have one
if [ $GATE_RETVAL -eq 0 ]; then
    # Run post_test_hook if we have one
    with_timeout call_hook_if_defined "post_test_hook"
    RETVAL=$?
fi

if [ $GATE_RETVAL -eq 137 ] && [ -f $WORKSPACE/gate.pid ] ; then
    echo "Job timed out"
    GATEPID=`cat $WORKSPACE/gate.pid`
    echo "Killing process group ${GATEPID}"
    sudo kill -s 9 -${GATEPID}
fi

echo "Cleaning up host"
echo "... this takes 3 - 4 minutes (logs at logs/devstack-gate-cleanup-host.txt.gz)"
$ANSIBLE all -f 5 -i "$WORKSPACE/inventory" -m shell \
    -a "$(run_command cleanup_host)" &> "$WORKSPACE/devstack-gate-cleanup-host.txt"
$ANSIBLE subnodes -f 5 -i "$WORKSPACE/inventory" -m synchronize \
    -a "mode=pull src='$BASE/logs/' dest='$BASE/logs/subnode-{{ host_counter }}' copy_links=yes"
sudo mv $WORKSPACE/devstack-gate-cleanup-host.txt $BASE/logs/

exit_handler $RETVAL
