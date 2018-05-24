#!/usr/bin/env bash

################################################
#
# KUBE_VERSION     the expected kubernetes version
# KUBEADM_VERSION  upgrader version
# eg.  ./kuberun.sh --role upgrade-masters \
#           --hosts 192.168.57.102,192.168.57.103,192.168.57.104 \
#           --kubeadm-version 1.8.0 \
#           --kube-version 1.7.5 \
#           --force
################################################

set -e -x

source $(cd `dirname ${BASH_SOURCE}`; pwd)/common.sh

public::common::nodeid

public::upgrade::current_version

#KUBEADM_VERSION=1.8.0

public::upgrade::current_version()
{
    export curr_version=$(kubectl version|grep -F 'Server'|awk -F "GitVersion:" '{print $2}'|cut -d '"' -f 2)
    export curr_version=${curr_version:1}
}

public::upgrade::kubeproxy()
{
    APISERVER_LB_ADDR=$(cat /etc/kubernetes/kube.conf |grep server|cut -d "/" -f 3)
    # replace kube-proxy apiserver endpoint to $APISERVER_LB
    kubectl -n=kube-system get configmap kube-proxy -o yaml > kube-proxy.yaml
    sed -i "s#server: https://.*\$#server: https://$APISERVER_LB_ADDR#g" kube-proxy.yaml
    kubectl -n=kube-system delete configmap kube-proxy
    kubectl create -f kube-proxy.yaml
    # recreate kube-proxy pod to enable new configmap
    kubectl -n=kube-system delete `kubectl -n=kube-system get pods -o name | grep kube-proxy`
}

public::upgrade::backup()
{
    local backup_dir=/etc/kubeadm/backup-$curr_version
    if [ ! -d $backup_dir ];then
        mkdir -p $backup_dir
        cp -rf /etc/kubernetes/ $backup_dir/
        cp /etc/systemd/system/kubelet.service.d/10-kubeadm.conf $backup_dir
        kubectl -n=kube-system get configmap kube-proxy -o yaml > $backup_dir/kube-proxy.yaml
    fi
}

public::main::upgrade()
{
    public::upgrade::kubeadm
    # 1. Download Kubernetes with VERSION
    # 2. Upgrade kubeadm package
    # 3. check support version。

    # Workaround : kubeadm use cfg.Nodename to compute hash to identify pod change. not suitable for multi-master
    #   change the nodeName every time to workaround.
    #if [ "$(kubeadm config view |grep "not found"|wc -l)" == "1" ];then

    sed "/imageRepository/d " /etc/kubeadm/kubeadm.cfg > /etc/kubeadm/kubeadm.cfg.new
    sed -i "N;4 a imageRepository: $KUBE_REPO_PREFIX" /etc/kubeadm/kubeadm.cfg.new
    kubeadm config upload from-file --config /etc/kubeadm/kubeadm.cfg.new
    #fi
    set +e
    kubectl delete clusterrolebindings kubeadm:node-autoapprove-bootstrap
    kubectl delete -n kube-public rolebindings kubeadm:bootstrap-signer-clusterinfo
    set -e

    public::upgrade::waitnodeready

    kubeadm upgrade apply -y $FORCE "v$KUBE_VERSION"

    public::upgrade::kubeproxy

    sed -i "/- kube-apiserver/a \    - --apiserver-count=100" /etc/kubernetes/manifests/kube-apiserver.yaml

    public::upgrade::kubelet

    public::common::log "Successful upgrade to [$KUBE_VERSION]. `hostname`"
}

public::upgrade::waitnodeready()
{
    for ((i=0;i<40;i++));do
        cnt=$(kubectl get no|grep NotReady|wc -l)
        if [ $cnt -eq 0 ];then
            break;
        fi
        sleep 3
    done
}

public::upgrade::kubelet()
{
    public::common::prepare_package "kubernetes" $KUBE_VERSION
    public::common::with_cidr

    if [ "$OS" == "CentOS" ];then
        dir=pkg/kubernetes/$KUBE_VERSION/rpm

        set +e; yum erase -y kubectl kubelet; set -e;
        yum localinstall -y `ls $dir | xargs -I '{}' echo -n "$dir/{} "`
#        yum localinstall -y $dir/`ls $dir | grep kubelet`
#        yum localinstall -y $dir/`ls $dir | grep kubectl`

        sed -i '/net.bridge.bridge-nf-call-iptables/d' /usr/lib/sysctl.d/00-system.conf
        sed -i '$a net.bridge.bridge-nf-call-iptables = 1' /usr/lib/sysctl.d/00-system.conf
        echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables
    elif [ "$OS" == "Ubuntu" ];then
        dir=pkg/kubernetes/$KUBE_VERSION/debain
        dpkg -i `ls $dir | xargs -I '{}' echo -n "$dir/{} "`
    fi

    sed -i "s#--cluster-dns=10.96.0.10 --cluster-domain=cluster.local#--cluster-dns=$CLUSTER_DNS \
        --pod-infra-container-image=$KUBE_REPO_PREFIX/pause-amd64:3.0 \
        --cluster-domain=cluster.local --cloud-provider=external --hostname-override=$NODE_ID#g" \
        /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    sed -i -e 's/cgroup-driver=systemd/cgroup-driver=cgroupfs/g' \
        /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

    systemctl daemon-reload ; systemctl enable kubelet ; systemctl restart kubelet

    public::common::log "Successful upgrade to [$KUBE_VERSION], Node. `hostname`"
}

# Install kubeadm , which is always used on masters
public::upgrade::kubeadm()
{
    public::common::prepare_package "kubernetes" "$KUBEADM_VERSION"

    dir=pkg/kubernetes/$KUBEADM_VERSION/rpm

    yum localinstall -y $dir/`ls $dir |grep kubeadm`
}



public::main::master()
{

    if version_gt $curr_version $KUBE_VERSION; then
       public::common::log "Current Version: $curr_version is greater than expected version: $KUBE_VERSION"
       if [ "$FORCE" != "--force" ];then
            public::common::log "And --force is not set , not continued, exit 1."
            exit 1
       fi
    fi

    if version_gt $KUBE_VERSION $KUBEADM_VERSION; then
       public::common::log "Upgrade.sh Version: $KUBEADM_VERSION is lower than expected version: $KUBE_VERSION"
       public::common::log "Which is not supported! exit 1"
       exit 1
    fi

    public::main::upgrade
}

public::main::node()
{
    public::upgrade::kubelet
}

main()
{
    while [[ $# -gt 0 ]]
    do
    key="$1"

    case $key in
        --role)
            export ROLE=$2
            shift
        ;;
        *)
            public::common::log "unkonw option [$key]"
        ;;
    esac
    shift
    done

    public::upgrade::backup

    ######################################################
    case $ROLE in

    "source")
        public::common::log "source scripts"
        ;;
    "master" )
        public::main::master
        ;;
    "node" )
        public::main::node
        ;;
    *)
        echo "
        export KUBEADM_VERSION=? KUBE_VERSION=?
        Usage:
            $0 --role source|master|node
        "
        ;;
    esac
}


main "$@"