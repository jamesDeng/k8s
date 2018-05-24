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
FILE_SERVER=http://aliacs-k8s-cn-hangzhou.oss-cn-hangzhou.aliyuncs.com

export CLOUD_TYPE=public

public::common::log(){
    echo $(date +"[%Y%m%d %H:%M:%S]: ") $1
}

public::common::prepare_package(){
    PKG_TYPE=$1
    PKG_VERSION=$2
    if [ ! -f ${PKG_TYPE}-${PKG_VERSION}.tar.gz ];then
        if [ -z $FILE_SERVER ] ;then
            public::common::log "local file ${PKG_TYPE}-${PKG_VERSION}.tar.gz does not exist, And FILE_SERVER is not config"
            public::common::log "installer does not known where to download installer binary package without FILE_SERVER env been set. Error: exit"
            exit 1
        fi
        public::common::log "local file ${PKG_TYPE}-${PKG_VERSION}.tar.gz does not exist, trying to download from [$FILE_SERVER]"
        curl --retry 4 $FILE_SERVER/$CLOUD_TYPE/pkg/$PKG_TYPE/${PKG_TYPE}-${PKG_VERSION}.tar.gz \
                > ${PKG_TYPE}-${PKG_VERSION}.tar.gz || (public::common::log "download failed with 4 retry,exit 1" && exit 1)
    fi
    tar -xvf ${PKG_TYPE}-${PKG_VERSION}.tar.gz || (public::common::log "untar ${PKG_TYPE}-${PKG_VERSION}.tar.gz failed!, exit" && exit 1)
}


RUN=run ; RUN_VERSION=1.0

rm -rf $RUN-$RUN_VERSION.tar.gz

public::common::prepare_package "$RUN" "$RUN_VERSION"

source $PKG/$RUN/$RUN_VERSION/etcd.sh --role source

source $PKG/$RUN/$RUN_VERSION/kubernetes.sh --role source

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
        --token  abc.abbbbbbbbb
        --endpoint 192.168.0.1:6443
        --load-images false
        --gpu-enabled
"
main "$@"

