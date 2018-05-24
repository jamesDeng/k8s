#!/usr/bin/env bash

PKG=pkg

public::common::region()
{
    region=$(curl --retry 5  -sSL http://100.100.100.200/latest/meta-data/region-id)
    if [ "" == "$region" ];then
        kube::common::log "can not get regionid and instanceid! \
            curl --retry 5 -sSL http://100.100.100.200/latest/meta-data/region-id" && exit 256
    fi
    if [ "$region" == "cn-beijing" \
        -o "$region" == "cn-shanghai" \
        -o "$region" == "cn-shenzhen" \
        -o "$region" == "cn-qingdao" \
        -o "$region" == "cn-zhangjiakou" ];then

        region=cn-hangzhou
    fi
    if [ "$region" == "cn-hongkong" ];then
        export KUBE_REPO_PREFIX=registry.cn-hangzhou.aliyuncs.com/google-containers
    fi
    export REGION=$region
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

public::common::os_env

public::common::region

# 首先从本地读取相应版本的tar包。当所需要的安装包不存在的时候
# 如果设置了参数PKG_FILE_SERVER，就从该Server上下载。
if [ "$PKG_FILE_SERVER" == "" ];then
    export PKG_FILE_SERVER=http://aliacs-k8s-$REGION.oss-$REGION.aliyuncs.com
fi

# 安装Kubernetes时候会启动一些AddOn插件的镜像。
# 改插件设置镜像仓库的前缀。
if [ "$KUBE_REPO_PREFIX" == "" ];then
    export KUBE_REPO_PREFIX=registry.$REGION.aliyuncs.com/google-containers
fi

export CLOUD_TYPE=public

public::common::log(){
    echo $(date +"[%Y%m%d %H:%M:%S]: ") $1
}

public::common::prepare_package(){
    PKG_TYPE=$1
    PKG_VERSION=$2
    if [ ! -f ${PKG_TYPE}-${PKG_VERSION}.tar.gz ];then
        if [ -z $PKG_FILE_SERVER ] ;then
            public::common::log "local file ${PKG_TYPE}-${PKG_VERSION}.tar.gz does not exist, And PKG_FILE_SERVER is not config"
            public::common::log "installer does not known where to download installer binary package without PKG_FILE_SERVER env been set. Error: exit"
            exit 1
        fi
        public::common::log "local file ${PKG_TYPE}-${PKG_VERSION}.tar.gz does not exist, trying to download from [$PKG_FILE_SERVER]"
        curl --retry 4 $PKG_FILE_SERVER/$CLOUD_TYPE/pkg/$PKG_TYPE/${PKG_TYPE}-${PKG_VERSION}.tar.gz \
                > ${PKG_TYPE}-${PKG_VERSION}.tar.gz || (public::common::log "download failed with 4 retry,exit 1" && exit 1)
    fi
    tar -xvf ${PKG_TYPE}-${PKG_VERSION}.tar.gz || (public::common::log "untar ${PKG_VERSION}.tar.gz failed!, exit" && exit 1)
}

public::common::nodeid()
{
    region=$(curl --retry 5  -sSL http://100.100.100.200/latest/meta-data/region-id)
    insid=$(curl --retry 5  -sSL http://100.100.100.200/latest/meta-data/instance-id)
    if [ "" == "$region" -o "" == "$insid" ];then
        kube::common::log "can not get regionid and instanceid! \
            curl --retry 5 -sSL http://100.100.100.200/latest/meta-data/region-id" && exit 256
    fi
    export NODE_ID=$region.$insid
}

public::common::with_cidr()
{
    gw=$(ip route |grep default|cut -d ' ' -f 3)
    # startwith

    if [[ $gw = "172."* ]];then
        export SVC_CIDR="192.168.255.0/20" CONTAINER_CIDR="192.168.0.0/20" CLUSTER_DNS="192.168.255.10"
    fi

    if [[ $gw = "10."* ]] ;then
        export SVC_CIDR="172.19.0.0/20" CONTAINER_CIDR="172.16.0.0/16" CLUSTER_DNS="172.19.0.10"
    fi

    if [[ $gw = "192.168"* ]];then
        export SVC_CIDR="172.19.0.0/20" CONTAINER_CIDR="172.16.0.0/16" CLUSTER_DNS="172.19.0.10"
    fi

    echo SVC_CIDR=$SVC_CIDR, CONTAINER_CIDR=$CONTAINER_CIDR, CLUSTER_DNS=$CLUSTER_DNS
}

function version_gt() { test "$(echo "$@" | tr " " "\n" | sort -V | head -n 1)" != "$1"; }
