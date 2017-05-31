#!/bin/bash
# Copyright 2017 Mirantis
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

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

if [ $(uname) = Darwin ]; then
  readlinkf(){ perl -MCwd -e 'print Cwd::abs_path shift' "$1";}
else
  readlinkf(){ readlink -f "$1"; }
fi

SCRIPT_DIR="$(cd $(dirname "$(readlinkf "${BASH_SOURCE}")"); pwd)"
virsh="${SCRIPT_DIR}/../../examples/virsh.sh"
vmssh="${SCRIPT_DIR}/../../examples/vmssh.sh"

# provide path for kubectl
export PATH="${HOME}/.kubeadm-dind-cluster:${PATH}"

function wait-for-pod {
  local pod="${1}"
  local n=180
  while true; do
    local phase="$(kubectl get pod "${1}" -o jsonpath='{.status.phase}')"
    if [[ ${phase} == Running ]]; then
      break
    fi
    if ((--n == 0)); then
      echo "Timed out waiting for pod ${pod}" >&2
      exit 1
    fi
    sleep 1
    echo -n "." >&2
  done
  echo >&2
}

wait-for-pod cirros-vm

cd "${SCRIPT_DIR}"
"${SCRIPT_DIR}/vmchat.exp" @cirros-vm

# test ceph RBD

vm_hostname="$("${vmssh}" cirros@cirros-vm cat /etc/hostname)"
expected_hostname=my-cirros-vm
if [[ "${vm_hostname}" != "${expected_hostname}" ]]; then
  echo "Unexpected vm hostname: ${vm_hostname} instead ${expected_hostname}" >&2
  exit 1
fi

virtlet_pod_name=$(kubectl get pods --namespace=kube-system | grep virtlet | awk '{print $1}')

# Run one-node ceph cluster
"${SCRIPT_DIR}/run_ceph.sh" "${SCRIPT_DIR}"

kubectl create -f "${SCRIPT_DIR}/cirros-vm-rbd-volume.yaml"
wait-for-pod cirros-vm-rbd
if [ "$(${virsh} domblklist @cirros-vm-rbd | grep rbd-test-image | wc -l)" != "1" ]; then
  echo "ceph: failed to find rbd-test-image in domblklist" >&2
  exit 1
fi

# wait for login prompt to appear
"${SCRIPT_DIR}/vmchat-short.exp" @cirros-vm-rbd

"${vmssh}" cirros@cirros-vm-rbd 'sudo /usr/sbin/mkfs.ext2 /dev/vdc && sudo mount /dev/vdc /mnt && ls -l /mnt | grep lost+found'

# check vnc consoles are available for both domains
if ! kubectl exec "${virtlet_pod_name}" --namespace=kube-system -- /bin/sh -c "apt-get install -y vncsnapshot"; then
  echo "Failed to install vncsnapshot inside virtlet container" >&2
  exit 1
fi

# grab screenshots

if ! kubectl exec "${virtlet_pod_name}" --namespace=kube-system -- /bin/sh -c "vncsnapshot :0 /domain_1.jpeg"; then
  echo "Failed to addtach and get screenshot for vnc console for domain with 1 id" >&2
  exit 1
fi

if ! kubectl exec "${virtlet_pod_name}" --namespace=kube-system -- /bin/sh -c "vncsnapshot :1 /domain_2.jpeg"; then
  echo "Failed to addtach and get screenshot for vnc console for domain with 2 id" >&2
  exit 1
fi

# check cpu count

function verify-cpu-count {
  local expected_count="${1}"
  cirros_cpu_count="$("${vmssh}" cirros@cirros-vm grep '^processor' /proc/cpuinfo|wc -l)"
  if [[ ${cirros_cpu_count} != ${expected_count} ]]; then
    echo "bad cpu count for cirros-vm: ${cirros_cpu_count} instead of ${expected_count}" >&2
    exit 1
  fi
}

verify-cpu-count 1

# test pod removal

kubectl delete pod cirros-vm
n=180
while kubectl get pod cirros-vm >&/dev/null; do
  if ((--n == 0)); then
    echo "Timed out waiting for pod removal" >&2
    exit 1
  fi
  sleep 1
  echo -n "." >&2
done
echo >&2

if "${virsh}" list --name|grep -- '-cirros-vm$'; then
  echo "cirros-vm domain still listed after deletion" >&2
  exit 1
fi

# test changing vcpu count

kubectl convert -f "${SCRIPT_DIR}/../../examples/cirros-vm.yaml" --local -o json | docker exec -i kube-master jq '.metadata.annotations.VirtletVCPUCount = "2" | .spec.containers[0].resources.limits.cpu = "500m"' | kubectl create -f -

wait-for-pod cirros-vm

# wait for login prompt to appear
"${SCRIPT_DIR}/vmchat-short.exp" @cirros-vm

verify-cpu-count 2

# verify domain memory size settings

function domain_xpath {
  local domain="${1}"
  local xpath="${2}"
  kubectl exec -n kube-system "${virtlet_pod_name}" -- \
          /bin/sh -c "virsh dumpxml '${domain}' | xmllint --xpath '${xpath}' -"
}

pod_domain="$("${virsh}" poddomain @cirros-vm)"

# <cputune>
#    <period>100000</period>
#    <quota>25000</quota>
# </cputune>
expected_dom_quota="25000"
expected_dom_period="100000"

dom_quota="$(domain_xpath "${pod_domain}" 'string(/domain/cputune/quota)')"
dom_period="$(domain_xpath "${pod_domain}" 'string(/domain/cputune/period)')"

if [[ ${dom_quota} != ${expected_dom_quota} ]]; then
  echo "Bad quota value in the domain definition. Expected ${dom_quota}, but got ${expected_dom_quota}" >&2
  exit 1
fi

if [[ ${dom_period} != ${expected_dom_period} ]]; then
  echo "Bad period value in the domain definition. Expected ${dom_period}, but got ${expected_dom_period}" >&2
  exit 1
fi

# <memory unit='KiB'>131072</memory>
dom_mem_size_k="$(domain_xpath "${pod_domain}" 'string(/domain/memory[@unit="KiB"])')"
expected_dom_mem_size_k="131072"
if [[ ${dom_mem_size_k} != ${expected_dom_mem_size_k} ]]; then
  echo "Bad memory size in the domain definition. Expected ${dom_mem_size_k}, but got ${expected_mem_size_k}" >&2
  exit 1
fi

# verify <memoryBacking><locked/></memoryBacking> in the domain definition
# (so the VM memory doesn't get swapped out)

if [[ $(domain_xpath "${pod_domain}" 'count(/domain/memoryBacking/locked)') != 1 ]]; then
  echo "Didn't find memoryBacking/locked in the domain definition" >&2
  exit 1
fi

# verify memory size as reported by Linux kernel inside VM

# The boot message is:
# [    0.000000] Memory: 109112k/130944k available (6576k kernel code, 452k absent, 21380k reserved, 6620k data, 928k init)

mem_size_k="$("${vmssh}" cirros@cirros-vm dmesg|grep 'Memory:'|sed 's@.*/\|k .*@@g')"
expected_mem_size_k=130944

if [[ ${mem_size_k} != ${expected_mem_size_k} ]]; then
  echo "Bad memory size (inside VM). Expected ${expected_mem_size_k}, but got ${mem_size_k}" >&2
  exit 1
fi
