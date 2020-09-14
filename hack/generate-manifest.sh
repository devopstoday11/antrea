#!/usr/bin/env bash

# Copyright 2019 Antrea Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -eo pipefail

function echoerr {
    >&2 echo "$@"
}

_usage="Usage: $0 [--mode (dev|release)] [--encap-mode] [--kind] [--ipsec] [--proxy] [--np] [--keep] [--tun (geneve|vxlan|gre|stt)] [--verbose-log] [--help|-h]
Generate a YAML manifest for Antrea using Kustomize and print it to stdout.
        --mode (dev|release)          Choose the configuration variant that you need (default is 'dev')
        --encap-mode                  Traffic encapsulation mode. (default is 'encap')
        --kind                        Generate a manifest appropriate for running Antrea in a Kind cluster
        --cloud                       Generate a manifest appropriate for running Antrea in Public Cloud
        --ipsec                       Generate a manifest with IPSec encryption of tunnel traffic enabled
        --proxy                       Generate a manifest with Antrea proxy enabled
        --np                          Generate a manifest with ClusterNetworkPolicy and Antrea NetworkPolicy features enabled
        --prometheus                  Generate a manifest with Antrea Controller and Agent Prometheus metrics listener enabled
        --keep                        Debug flag which will preserve the generated kustomization.yml
        --tun (geneve|vxlan|gre|stt)  Choose encap tunnel type from geneve, gre, stt and vxlan (default is geneve)
        --verbose-log                 Generate a manifest with increased log-level (level 4) for Antrea agent and controller.
                                      This option will work only with 'dev' mode.
        --on-delete                   Generate a manifest with antrea-agent's update strategy set to OnDelete.
                                      This option will work only for Kind clusters (when using '--kind').
        --coverage                    Generates a manifest which supports measuring code coverage of Antrea binaries.
        --help, -h                    Print this message and exit

In 'release' mode, environment variables IMG_NAME and IMG_TAG must be set.

This tool uses kustomize (https://github.com/kubernetes-sigs/kustomize) to generate manifests for
Antrea. You can set the KUSTOMIZE environment variable to the path of the kustomize binary you want
us to use. Otherwise we will download the appropriate version of the kustomize binary and use
it (this is the recommended approach since different versions of kustomize may create different
output YAMLs)."

function print_usage {
    echoerr "$_usage"
}

function print_help {
    echoerr "Try '$0 --help' for more information."
}

MODE="dev"
KIND=false
IPSEC=false
PROXY=false
NP=false
KEEP=false
ENCAP_MODE=""
CLOUD=""
TUN_TYPE="geneve"
VERBOSE_LOG=false
ON_DELETE=false
COVERAGE=false
PROMETHEUS=false

while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    --mode)
    MODE="$2"
    shift 2
    ;;
    --encap-mode)
    ENCAP_MODE="$2"
    shift 2
    ;;
    --cloud)
    CLOUD="$2"
    shift 2
    ;;
    --kind)
    KIND=true
    shift
    ;;
    --ipsec)
    IPSEC=true
    shift
    ;;
    --proxy)
    PROXY=true
    shift
    ;;
    --np)
    NP=true
    shift
    ;;
    --prometheus)
    PROMETHEUS=true
    shift
    ;;
    --keep)
    KEEP=true
    shift
    ;;
    --tun)
    TUN_TYPE="$2"
    shift 2
    ;;
    --verbose-log)
    VERBOSE_LOG=true
    shift
    ;;
    --on-delete)
    ON_DELETE=true
    shift
    ;;
    --coverage)
    COVERAGE=true
    shift
    ;;
    -h|--help)
    print_usage
    exit 0
    ;;
    *)    # unknown option
    echoerr "Unknown option $1"
    exit 1
    ;;
esac
done

if [ "$MODE" != "dev" ] && [ "$MODE" != "release" ]; then
    echoerr "--mode must be one of 'dev' or 'release'"
    print_help
    exit 1
fi

if [ "$TUN_TYPE" != "geneve" ] && [ "$TUN_TYPE" != "vxlan" ] && [ "$TUN_TYPE" != "gre" ] && [ "$TUN_TYPE" != "stt" ]; then
    echoerr "--tun must be one of 'geneve', 'gre', 'stt' or 'vxlan'"
    print_help
    exit 1
fi

if [ "$MODE" == "release" ] && [ -z "$IMG_NAME" ]; then
    echoerr "In 'release' mode, environment variable IMG_NAME must be set"
    print_help
    exit 1
fi

if [ "$MODE" == "release" ] && [ -z "$IMG_TAG" ]; then
    echoerr "In 'release' mode, environment variable IMG_TAG must be set"
    print_help
    exit 1
fi

if [ "$MODE" == "release" ] && $VERBOSE_LOG; then
    echoerr "--verbose-log works only with 'dev' mode"
    print_help
    exit 1
fi

if ! $KIND && $ON_DELETE; then
    echoerr "--on-delete works only for Kind clusters"
    print_help
    exit 1
fi

# noEncap/policy-only mode works with antrea-proxy.
if [[ "$ENCAP_MODE" != "" ]] && [[ "$ENCAP_MODE" != "encap" ]]; then
      PROXY=true
fi

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

source $THIS_DIR/verify-kustomize.sh

if [ -z "$KUSTOMIZE" ]; then
    KUSTOMIZE="$(verify_kustomize)"
elif ! $KUSTOMIZE version > /dev/null 2>&1; then
    echoerr "$KUSTOMIZE does not appear to be a valid kustomize binary"
    print_help
    exit 1
fi

KUSTOMIZATION_DIR=$THIS_DIR/../build/yamls

TMP_DIR=$(mktemp -d $KUSTOMIZATION_DIR/overlays.XXXXXXXX)

pushd $TMP_DIR > /dev/null

BASE=../../base

# do all ConfigMap edits
mkdir configMap && cd configMap
# user is not expected to make changes directly to antrea-agent.conf and antrea-controller.conf,
# but instead to the generated YAML manifest, so our regexs need not be too robust.
cp $KUSTOMIZATION_DIR/base/conf/antrea-agent.conf antrea-agent.conf
cp $KUSTOMIZATION_DIR/base/conf/antrea-controller.conf antrea-controller.conf
if $KIND; then
    sed -i.bak -E "s/^[[:space:]]*#[[:space:]]*ovsDatapathType[[:space:]]*:[[:space:]]*[a-z]+[[:space:]]*$/ovsDatapathType: netdev/" antrea-agent.conf
fi

if $IPSEC; then
    sed -i.bak -E "s/^[[:space:]]*#[[:space:]]*enableIPSecTunnel[[:space:]]*:[[:space:]]*[a-z]+[[:space:]]*$/enableIPSecTunnel: true/" antrea-agent.conf
    # change the tunnel type to GRE which works better with IPSec encryption than other types.
    sed -i.bak -E "s/^[[:space:]]*#[[:space:]]*tunnelType[[:space:]]*:[[:space:]]*[a-z]+[[:space:]]*$/tunnelType: gre/" antrea-agent.conf
fi

if $PROXY; then
    sed -i.bak -E "s/^[[:space:]]*#[[:space:]]*AntreaProxy[[:space:]]*:[[:space:]]*[a-z]+[[:space:]]*$/  AntreaProxy: true/" antrea-agent.conf
fi

if $NP; then
    sed -i.bak -E "s/^[[:space:]]*#[[:space:]]*AntreaPolicy[[:space:]]*:[[:space:]]*[a-z]+[[:space:]]*$/  AntreaPolicy: true/" antrea-controller.conf
    sed -i.bak -E "s/^[[:space:]]*#[[:space:]]*AntreaPolicy[[:space:]]*:[[:space:]]*[a-z]+[[:space:]]*$/  AntreaPolicy: true/" antrea-agent.conf
fi

if $PROMETHEUS; then
    sed -i.bak -E "s/^[[:space:]]*#[[:space:]]*enablePrometheusMetrics[[:space:]]*:[[:space:]]*[a-z]+[[:space:]]*$/enablePrometheusMetrics: true/" antrea-controller.conf
    sed -i.bak -E "s/^[[:space:]]*#[[:space:]]*enablePrometheusMetrics[[:space:]]*:[[:space:]]*[a-z]+[[:space:]]*$/enablePrometheusMetrics: true/" antrea-agent.conf
fi

if [[ $ENCAP_MODE != "" ]]; then
    sed -i.bak -E "s/^[[:space:]]*#[[:space:]]*trafficEncapMode[[:space:]]*:[[:space:]]*[a-z]+[[:space:]]*$/trafficEncapMode: $ENCAP_MODE/" antrea-agent.conf
fi

if [[ $TUN_TYPE != "geneve" ]]; then
    sed -i.bak -E "s/^[[:space:]]*#[[:space:]]*tunnelType[[:space:]]*:[[:space:]]*[a-z]+[[:space:]]*$/tunnelType: $TUN_TYPE/" antrea-agent.conf
fi

if [[ $CLOUD != "" ]]; then
    # Delete the serviceCIDR parameter for the cloud (AKS, EKS, GKE) deployment yamls, because
    # AntreaProxy is always enabled for the cloud managed K8s clusters, and the serviceCIDR
    # parameter is not needed in this case.
    # delete all blank lines after "#serviceCIDR:"
    sed -i.bak '/#serviceCIDR:/,/^$/{/^$/d;}' antrea-agent.conf
    # delete lines from "# ClusterIP CIDR range for Services" to "#serviceCIDR:"
    sed -i.bak '/# ClusterIP CIDR range for Services/,/#serviceCIDR:/d' antrea-agent.conf
fi

# unfortunately 'kustomize edit add configmap' does not support specifying 'merge' as the behavior,
# which is why we use a template kustomization file.
sed -e "s/<AGENT_CONF_FILE>/antrea-agent.conf/; s/<CONTROLLER_CONF_FILE>/antrea-controller.conf/" ../../patches/kustomization.configMap.tpl.yml > kustomization.yml
$KUSTOMIZE edit add base $BASE
BASE=../configMap
cd ..

if $IPSEC; then
    mkdir ipsec && cd ipsec
    # we copy the patch files to avoid having to use the '--load-restrictor. flag when calling
    # 'kustomize build'. See https://github.com/kubernetes-sigs/kustomize/blob/master/docs/FAQ.md#security-file-foo-is-not-in-or-below-bar
    cp ../../patches/ipsec/*.yml .
    touch kustomization.yml
    $KUSTOMIZE edit add base $BASE
    # create a K8s Secret to save the PSK (pre-shared key) for IKE authentication.
    $KUSTOMIZE edit add resource ipsecSecret.yml
    # add a container to the Agent DaemonSet that runs the OVS IPSec and strongSwan daemons.
    $KUSTOMIZE edit add patch ipsecContainer.yml
    # add an environment variable to the antrea-agent container for passing the PSK to Agent.
    $KUSTOMIZE edit add patch pskEnv.yml
    BASE=../ipsec
    cd ..
fi

if $COVERAGE; then
    mkdir coverage && cd coverage
    cp ../../patches/coverage/*.yml .
    touch kustomization.yml
    $KUSTOMIZE edit add base $BASE
    # this runs antrea-controller via the instrumented binary.
    $KUSTOMIZE edit add patch startControllerCov.yml
    # this runs antrea-agent via the instrumented binary.
    $KUSTOMIZE edit add patch startAgentCov.yml
    BASE=../coverage
    cd ..
fi 

if [[ $ENCAP_MODE == "networkPolicyOnly" ]] ; then
    mkdir chaining && cd chaining
    cp ../../patches/chaining/*.yml .
    touch kustomization.yml
    $KUSTOMIZE edit add base $BASE
    # change initContainer script and add antrea to CNI chain
    $KUSTOMIZE edit add patch installCni.yml
    BASE=../chaining
    cd ..
fi

if [[ $CLOUD == "GKE" ]]; then
    mkdir gke && cd gke
    cp ../../patches/gke/*.yml .
    touch kustomization.yml
    $KUSTOMIZE edit add base $BASE
    $KUSTOMIZE edit add patch cniPath.yml
    BASE=../gke
    cd ..
fi

if [[ $CLOUD == "EKS" ]]; then
    mkdir eks && cd eks
    cp ../../patches/eks/*.yml .
    touch kustomization.yml
    $KUSTOMIZE edit add base $BASE
    $KUSTOMIZE edit add patch eksEnv.yml
    BASE=../eks
    cd ..
fi

if $KIND; then
    mkdir kind && cd kind
    cp ../../patches/kind/*.yml .
    touch kustomization.yml
    $KUSTOMIZE edit add base $BASE

    # add tun device to antrea OVS container
    $KUSTOMIZE edit add patch tunDevice.yml
    # antrea-ovs should use start_ovs_netdev instead of start_ovs to ensure that the br-phy bridge
    # is created.
    $KUSTOMIZE edit add patch startOvs.yml
    # this adds a small delay before running the antrea-agent process, to give the antrea-ovs
    # container enough time to set up the br-phy bridge.
    # workaround for https://github.com/vmware-tanzu/antrea/issues/801
    if $COVERAGE; then
        cp ../../patches/coverage/startAgentCov.yml .
        $KUSTOMIZE edit add patch startAgentCov.yml 
    else
        $KUSTOMIZE edit add patch startAgent.yml
    fi
    # change initContainer script and remove SYS_MODULE capability
    $KUSTOMIZE edit add patch installCni.yml

    if $ON_DELETE; then
        $KUSTOMIZE edit add patch onDeleteUpdateStrategy.yml
    fi

    BASE=../kind
    cd ..
fi

mkdir $MODE && cd $MODE
touch kustomization.yml
$KUSTOMIZE edit add base $BASE
# ../../patches/$MODE may be empty so we use find and not simply cp
find ../../patches/$MODE -name \*.yml -exec cp {} . \;

if [ "$MODE" == "dev" ]; then
    $KUSTOMIZE edit set image antrea=antrea/antrea-ubuntu:latest
    $KUSTOMIZE edit add patch agentImagePullPolicy.yml
    $KUSTOMIZE edit add patch controllerImagePullPolicy.yml
    if $VERBOSE_LOG; then
        $KUSTOMIZE edit add patch agentVerboseLog.yml
        $KUSTOMIZE edit add patch controllerVerboseLog.yml
    fi

    # only required because there is no good way at the moment to update the imagePullPolicy for all
    # containers. See https://github.com/kubernetes-sigs/kustomize/issues/1493
    if $IPSEC; then
        $KUSTOMIZE edit add patch agentIpsecImagePullPolicy.yml
    fi
fi

if [ "$MODE" == "release" ]; then
    $KUSTOMIZE edit set image antrea=$IMG_NAME:$IMG_TAG
fi

$KUSTOMIZE build

popd > /dev/null

if $KEEP; then
    echoerr "Kustomization file is at $TMP_DIR/$MODE/kustomization.yml"
else
    rm -rf $TMP_DIR
fi
