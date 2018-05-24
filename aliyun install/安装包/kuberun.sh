#!/usr/bin/env bash
set -e -x

PKG=pkg

#################################################################################
# @author: spacexnice@github
# @date:   2017-02-06
# @parameter:
#   PKG_FILE_SERVER set the package download server. default to regionize oss store.
#   PKG_FILE_SERVER=
#
#
# FILE_SERVER=http://aliacs-k8s.oss-cn-hangzhou.aliyuncs.com
# 首先从本地读取相应版本的tar包。当所需要的安装包不存在的时候
# 如果设置了参数PKG_FILE_SERVER，就从该Server上下载。


public::common::log(){
    echo $(date +"[%Y%m%d %H:%M:%S]: ") $1
}

RUN=run ;

if [ "$RUN_VERSION" == "" ];then
    RUN_VERSION=1.0
fi

rm -rf $RUN-$RUN_VERSION.tar.gz

tar -cvf $RUN-$RUN_VERSION.tar.gz pkg

#public::common::prepare_package "$RUN" "$RUN_VERSION"

source $PKG/$RUN/$RUN_VERSION/etcd.sh --role source

#source $PKG/$RUN/$RUN_VERSION/kubernetes.sh --role source

public::common::common_env(){

    public::common::os_env

    if [ -z $EXTRA_SANS ];then
        export EXTRA_SANS=1.1.1.1
    fi
}

public::common::os_env()
{
    ubu=$(cat /etc/issue|grep "Ubuntu 16.04"|wc -l)
    cet=$(cat /etc/centos-release|grep "CentOS"|wc -l)
    if [ "$ubu" == "1" ];then
        export OS="Ubuntu"
    elif [ "$cet" == "1" ];then
        export OS="CentOS"
    else
       public::common::log "unkown os...   exit"
       exit 1
    fi
}


public::common::scripts()
{
    export NODES=${HOSTS//,/$'\n'}

    i=0 ;

    for host in $NODES;
    do
        public::common::log "copy scripts:$host"
        cat $RUN-$RUN_VERSION.tar.gz | ssh -e none root@$host "cat > $RUN-$RUN_VERSION.tar.gz; tar xf $RUN-$RUN_VERSION.tar.gz"
    done
}

public::main::clean_cache()
{
    export NODES=${HOSTS//,/$'\n'}

    i=0 ;
    files="run-1.0.tar.gz kubernetes-1.7.2.tar.gz etcd-v3.0.17.tar.gz"
    for host in $NODES;
    do
        public::common::log "clean cache file:$host, "
        ssh -e none root@$host "rm -rf $files"
    done
}

public::main::upgrade_masters()
{
    if [ "$KUBE_VERSION" == "" -o "$KUBEADM_VERSION" == "" ];then
        public::common::log "Error: either export KUBE_VERSION or specify --kube-version "
        exit 1
    fi

    export MASTERS=${HOSTS//,/$'\n'}

    for host in $MASTERS;
    do
        public::common::log "upgrade master:$host"
        ssh -e none root@$host "export KUBEADM_VERSION=$KUBEADM_VERSION; \
            KUBE_VERSION=$KUBE_VERSION \
            FORCE=$FORCE \
            bash $PKG/$RUN/$RUN_VERSION/upgrade.sh --role master"
    done
}

public::main::upgrade_nodes()
{
    if [ "$KUBE_VERSION" == "" -o "$KUBEADM_VERSION" == "" ];then
        public::common::log "Error: either export KUBE_VERSION or specify --kube-version "
        exit 1
    fi

    export NODES=${HOSTS//,/$'\n'}

    for host in $NODES;
    do
        public::common::log "upgrade master:$host"
        ssh -e none root@$host "export KUBEADM_VERSION=$KUBEADM_VERSION; \
            KUBE_VERSION=$KUBE_VERSION \
            bash $PKG/$RUN/$RUN_VERSION/upgrade.sh --role node"
    done
}
main()
{
    public::common::parse_args "$@"
    public::common::common_env

    public::common::scripts

    case $ROLE in

    "deploy-etcd" )
        public::etcd::deploy
        ;;
    "deploy-masters" )
        public::master::deploy
        ;;
    "deploy-nodes" )
        public::node::deploy
        ;;
    "destroy-etcd" )
        public::etcd::destroy
        ;;
    "destroy-nodes" )
        public::main::destroy_cluster
        ;;
    "clean-cache" )
        public::main::clean_cache
        ;;
    "upgrade-masters" )
        public::main::upgrade_masters
        ;;
    "upgrade-nodes" )
        public::main::upgrade_nodes
        ;;
    *)
        echo "$help"
        ;;
    esac
}
help="
Usage:
    "$0"
        --role deploy  [deploy-etcd | deploy-masters | deploy-nodes | destroy-etcd | destroy-nodes | clean-cache]
        --container-cidr 172.16.0.0
        --hosts 192.168.0.1,192.168.0.2,192.168.0.3
        --etcd-hosts 192.168.0.1,192.168.0.2,192.168.0.3
        --apiserver-lb 1.1.1.1,2.2.2.2
        --extra-sans 3.3.3.3,4.4.4.4
        --key abcdefghigk
        --key-secret abcdifffffffff

        --docker-version 17.06.ce
        --etcd-version v3.0.17
        --cms-version 1.2.21
        --token  abc.abbbbbbbbb
        --endpoint 192.168.0.1:6443
        --load-images false
        --gpu-enabled
        --cms-enabled
"
main "$@"

