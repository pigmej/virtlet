#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o errtrace
/start.sh -novirtlet

./autogen.sh
./configure
make
make install
cd tests/integration

if ! VIRTLET_DISABLE_KVM=1 ./go.test; then
    if [[ -f /tmp/libvirt.log ]]; then
        echo >&2 '**** libvirt.log:'
        cat /tmp/libvirt.log >&2
    else
        echo >&2 '**** libvirt.log not found'
    fi

    if [[ -f /tmp/xxx.txt ]]; then
        echo >&2 '**** libvirt.log:'
        cat /tmp/xxx.txt >&2
    else
        echo >&2 '**** /tmp/xxx.txt not found'
    fi

    ls -l /
    cat /vmwrapper-pre-qemu.sh >&2 || true
    # for f in /var/log/libvirt/qemu/*.log; do
    #     echo >&2 "**** $f:"
    #     cat "$f" >&2
    # done

    # if [[ -f /var/log/libvirt/qemu/cirros.log ]]; then
    #     echo >&2 '**** cirros.log:'
    #     cat /var/log/libvirt/qemu/cirros.log >&2
    # else
    #     echo >&2 '**** cirros.log not found'
    # fi

    exit 1
else
    if [[ -f /tmp/libvirt.log ]]; then
        echo >&2 '**** libvirt.log:'
        cat /tmp/libvirt.log >&2
    else
        echo >&2 '**** libvirt.log not found'
    fi

    if [[ -f /tmp/xxx.txt ]]; then
        echo >&2 '**** libvirt.log:'
        cat /tmp/xxx.txt >&2
    else
        echo >&2 '**** /tmp/xxx.txt not found'
    fi

    ls -l /
    cat /vmwrapper-pre-qemu.sh >&2 || true
fi

echo "----QQQ"
ls -l /tmp
echo "----QQQ"

# if ! VIRTLET_DISABLE_KVM=1 make check; then
#     find . -name test-suite.log | xargs cat
#     exit 1
# fi
