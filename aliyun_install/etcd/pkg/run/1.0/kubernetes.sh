#!/usr/bin/env bash

set -x -e

source $(cd `dirname ${BASH_SOURCE}`; pwd)/common.sh

source $(cd `dirname ${BASH_SOURCE}`; pwd)/nvidia-gpu.sh

public::common::install_package(){

    public::docker::install

    public::common::prepare_package "kubernetes" $KUBE_VERSION

    if [ "$OS" == "CentOS" ];then
        dir=pkg/kubernetes/$KUBE_VERSION/rpm

        yum localinstall -y `ls $dir | xargs -I '{}' echo -n "$dir/{} "`

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

    systemctl daemon-reload ; systemctl enable kubelet.service ; systemctl start kubelet.service
}

public::docker::install()
{
    set +e
    docker version > /dev/null 2>&1
    i=$?
    set -e
    v=$(docker version|grep Version|awk '{gsub(/-/, ".");print $2}'|uniq)
    if [ $i -eq 0 ]; then
        if [[ "$DOCKER_VERSION" == "$v" ]];then
            public::common::log "docker has been installed , return. $DOCKER_VERSION"
            return
        fi
    fi
    public::common::prepare_package "docker" $DOCKER_VERSION
    if [ "$OS" == "CentOS" ];then
        if [ "$(rpm -qa docker-engine-selinux|wc -l)" == "1" ];then
            yum erase -y docker-engine-selinux
        fi
        if [ "$(rpm -qa docker-engine|wc -l)" == "1" ];then
            yum erase -y docker-engine
        fi
        if [ "$(rpm -qa docker-ce|wc -l)" == "1" ];then
            yum erase -y docker-ce
        fi
        if [ "$(rpm -qa container-selinux|wc -l)" == "1" ];then
            yum erase -y container-selinux
        fi

        if [ "$(rpm -qa docker-ee|wc -l)" == "1" ];then
            yum erase -y docker-ee
        fi

        local pkg=pkg/docker/$DOCKER_VERSION/rpm/
        yum localinstall -y `ls $pkg |xargs -I '{}' echo -n "$pkg{} "`
    elif [ "$OS" == "Ubuntu" ];then
        if [ "$need_reinstall" == "true" ];then
            if [ "$(echo $v|grep ee|wc -l)" == "1" ];then
                apt purge -y docker-ee docker-ee-selinux
            elif [ "$(echo $v|grep ce|wc -l)" == "1" ];then
                apt purge -y docker-ce docker-ce-selinux container-selinux
            else
                apt purge -y docker-engine
            fi
        fi
        dir=pkg/docker/$DOCKER_VERSION/debain
        dpkg -i `ls $dir | xargs -I '{}' echo -n "$dir/{} "`
    else
        public::common::log "install docker with [unsupported OS version] error!"
        exit 1
    fi
    public::docker::config
}

public::docker::config()
{
    iptables -P FORWARD ACCEPT
    if [ "$OS" == "CentOS" ];then
        #setenforce 0
        sed -i -e 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
    fi
    sed -i "s#ExecStart=/usr/bin/dockerd#ExecStart=/usr/bin/dockerd -s overlay \
        --registry-mirror=https://pqbap4ya.mirror.aliyuncs.com --log-driver=json-file \
        --log-opt max-size=100m --log-opt max-file=10#g" /lib/systemd/system/docker.service

    sed -i "/ExecStart=/a\ExecStartPost=/usr/sbin/iptables -P FORWARD ACCEPT" /lib/systemd/system/docker.service

    systemctl daemon-reload ; systemctl enable  docker.service; systemctl restart docker.service
}

public::docker::load_images()
{
    local app=images; local ver=v1.0
    agility::common::prepare_package $app $ver
    for img in `ls pkg/$app/$ver/common/`;do
        # 判断镜像是否存在，不存在才会去load
        ret=$(docker images | awk 'NR!=1{print $1"_"$2".tar"}'| grep $KUBE_REPO_PREFIX/$img | wc -l)
        if [ $ret -lt 1 ];then
            docker load < pkg/$app/$ver/common/$img
        fi
    done

    docker tag registry.cn-hangzhou.aliyuncs.com/google-containers/pause-amd64:3.0 \
        gcr.io/google_containers/pause-amd64:3.0 >/dev/null
}

public::common::cluster_addon(){
    dir=pkg/kubernetes/$KUBE_VERSION/module
    sed -i "s#10.244.0.0/16#$CONTAINER_CIDR#g" $dir/flannel-vpc-rbac.yml

    for h in ${HOSTS//,/$'\n'};
    do
        server=${server}"\ \ \ \ \ \ \ \ \ \ \ \ server $h:6443;"
    done
    sed "/least_conn/a\\
        ${server}" $dir/apiserver-proxy.yml.tpl > $dir/apiserver-proxy.yml


    kubectl create secret generic kubernetes-dashboard-certs --from-file=/etc/kubernetes/pki/dashboard/ -n kube-system

    kubectl apply -f $dir/cloud-controller-manager.yml \
            -f $dir/heapster.yml \
            -f $dir/flannel-vpc-rbac.yml \
            -f $dir/ingress-controller.yml \
            -f $dir/kubernetes-dashboard-1.7.yml \
            -f $dir/jenkins.yml
            # -f $dir/apiserver-proxy.yml
}

public::common::manifests()
{
    dir=/etc/kubernetes/manifests/
    while [ ! -f $dir/kube-apiserver.yaml ];
    do
        public::common::log "wait for manifests to be ready." ; sleep 3
    done

    for file in `ls $dir`
    do
        sed -i '/image/a\ \ \ \ imagePullPolicy: IfNotPresent' $dir/$file
    done
}

public::wait_apiserver()
{
    ret=1
    while [[ $ret != 0 ]]; do
        sleep 2
        curl -k https://127.0.0.1:6443 2>&1>/dev/null
        ret=$?
    done
}

public::main::destroy_cluster(){
    export MASTERS=${HOSTS//,/$'\n'}

    i=0 ; rm -rf pki.tar

    self=$(cd `dirname $0`; pwd)/`basename $0`
    for host in $MASTERS;
    do
        public::common::log "BEGAIN: init master:$host"

        # upload script. Major master
        ssh -e none root@$host "bash $PKG/$RUN/$RUN_VERSION/kubernetes.sh --role node-down --hosts $HOSTS "
#                --extra-sans $EXTRA_SANS --apiserver-lb $APISERVER_LB \
#                --docker-version $DOCKER_VERSION --container-cidr $CIDR --etcd-hosts $ETCD_HOSTS"

    done

}

public::node::node_down(){
    set +e
    systemctl stop kubelet.service
    kubeadm reset
    docker ps -aq|xargs -I '{}' docker stop {}
    docker ps -aq|xargs -I '{}' docker rm {}
    df |grep /var/lib/kubelet|awk '{ print $6 }'|xargs -I '{}' umount {}
    rm -rf /var/lib/kubelet && rm -rf /etc/kubernetes/
    if [ "$OS" == "CentOS" ];then
        yum remove -y kubectl kubeadm kubelet kubernetes-cni
    elif [ "$OS" == "Ubuntu" ];then
        apt purge -y kubectl kubeadm kubelet kubernetes-cni
    fi
    rm -rf /var/lib/cni
    ip link del cni0
    set -e
}
public::common::cloud_config()
{
    mkdir -p /etc/kubernetes
    cat >/etc/kubernetes/cloud-config <<EOF
{
    "global": {
     "accessKeyID": "$KEY_ID",
     "accessKeySecret": "$KEY_SECRET",
     "kubernetesClusterTag": "kubernetes-$(uuidgen |awk -F - '{print $5}')"
   }
}
EOF
}

public::common::kubeadm_config()
{
    mkdir -p /etc/kubeadm/ /etc/kubernetes/pki/etcd/
    cp -rf /var/lib/etcd/cert/{ca.pem,etcd-client.pem,etcd-client-key.pem} /etc/kubernetes/pki/etcd/

    for h in ${ETCD_HOSTS//,/$'\n'};
    do
        endpoint=${endpoint}"- https://$h:2379\n  "
        ep_san=${ep_san}"- $h\n  "
    done

    for h in ${EXTRA_SANS//,/$'\n'};
    do
        sans=$sans"- $h\n  "
    done

    for h in ${APISERVER_LB//,/$'\n'};
    do
        lbs=$lbs"- $h\n  "
    done
    cat >/etc/kubeadm/kubeadm.cfg <<EOF
apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
cloudProvider: external
imageRepository: $KUBE_REPO_PREFIX
selfHosted: false
networking:
  dnsDomain: cluster.local
  serviceSubnet: $SVC_CIDR
  podSubnet: $CONTAINER_CIDR
etcd:
  endpoints:
  `echo -e "$endpoint"`
  caFile: /etc/kubernetes/pki/etcd/ca.pem
  certFile: /etc/kubernetes/pki/etcd/etcd-client.pem
  keyFile: /etc/kubernetes/pki/etcd/etcd-client-key.pem
apiServerCertSANs:
  `echo -e "$lbs"`
  `echo -e "$sans"`
  `echo -e "$ep_san"`
token: $TOKEN
nodeName: $NODE_ID
kubernetesVersion: v${KUBE_VERSION}
EOF
}

public::main::init_master(){

    public::common::master_env

    public::common::nodeid

    public::common::cloud_config

    MASTER_MAJOR=$1
    public::common::kubeadm_config

    public::common::install_package

    if [ "$LOAD_IMAGE" == "true" ];then
        public::docker::load_images master
    fi

    # support kubernetes with GPU
    if [ "1" == "$GPU_ENABLED" ];then
        public::nvidia::enable_gpu_in_kube
    else
        echo "Skip the step for non-GPU master"
    fi

    ###########################################################
    # Do init master, if version ge 1.8.0, will write node join
    # command into /etc/kubeadm/kubejoin.sh
    out=$(kubeadm init --config /etc/kubeadm/kubeadm.cfg)
    echo "$out" |grep "kubeadm join"|grep "discovery-token-ca-cert-hash"|awk -F " " '{print $6" "$7}' > /etc/kubeadm/kubejoin.sh
    chmod +x /etc/kubeadm/kubejoin.sh
    public::common::log "$out"
    ###########################################################

    public::common::manifests

    # 使能master，可以被调度到
    # kubectl taint nodes --all dedicated-

    ## generate cloud-controller-manager config
    cp -rf pkg/kubernetes/$KUBE_VERSION/module/cloud-controller.conf \
        /etc/kubernetes/cloud-controller-manager.conf
    head -6 /etc/kubernetes/controller-manager.conf >> /etc/kubernetes/cloud-controller-manager.conf

    # 添加kubernetes-dashboard 证书，添加控制台CA
    if [ ! -f /etc/kubernetes/pki/client-ca.crt ];then
        touch /etc/kubernetes/pki/client-ca.crt
    fi
    cat /etc/kubernetes/pki/client-ca.crt >> /etc/kubernetes/pki/apiserver.crt
    cp -rf /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/dashboard/dashboard.crt
    cp -rf /etc/kubernetes/pki/apiserver.key /etc/kubernetes/pki/dashboard/dashboard.key
    cp -rf /etc/kubernetes/pki/ca.crt /etc/kubernetes/pki/dashboard/dashboard-ca.crt
    cat /etc/kubernetes/pki/client-ca.crt >> /etc/kubernetes/pki/dashboard/dashboard-ca.crt

    export KUBECONFIG=/etc/kubernetes/admin.conf

    if [ "$MASTER_MAJOR" == "major" ];then
        public::common::cluster_addon

        # show pods
        kubectl get po --all-namespaces ;

        kubeadm token list |awk 'NR==2{print $1}' > /etc/kubernetes/pki/token.csv

        tar -cf /etc/kubernetes/pki.tar -C /etc/kubernetes/ \
            pki/{token.csv,sa.key,sa.pub,ca.crt,ca.key,front-proxy-ca.key,front-proxy-ca.crt}

    fi

    ## deal with v1.8.0 csr-controller permission fix;
    kubectl apply -f pkg/kubernetes/$KUBE_VERSION/module/csr-role.yml

    # 调整kubelet.conf的apiserver 地址
    sed "/server: https:/d" /etc/kubernetes/admin.conf | \
        sed "/- cluster:/a \    server: https://`echo $EXTRA_SANS|awk -F, '{print $1}'`:6443" >/etc/kubernetes/kube.conf

    sed -i "/- kube-apiserver/a \    - --apiserver-count=500" /etc/kubernetes/manifests/kube-apiserver.yaml

    systemctl restart kubelet; systemctl restart docker

    echo "export KUBECONFIG=/etc/kubernetes/admin.conf" >> ~/.bashrc

    echo "K8S master install finished!"
}
public::main::post_init()
{
#    amend="
#    {
#        \"spec\":{
#            \"template\":{
#                \"spec\":{
#                    \"containers\":[
#                        {
#                            \"name\":\"kube-proxy\",
#                            \"command\":[
#                                \"/usr/local/bin/kube-proxy\",
#                                \"--kubeconfig=/var/lib/kube-proxy/kubeconfig.conf\",
#                                \"--cluster-cidr=$CONTAINER_CIDR\",
#                                \"--hostname-override=$NODEID\"
#                             ]
#                        }
#                    ]
#                }
#            }
#        }
#    }
#    "
#    kubectl patch -n kube-system ds kube-proxy -p "$amend"


    # replace kube-proxy apiserver endpoint to $APISERVER_LB
    kubectl -n=kube-system get configmap kube-proxy -o yaml > kube-proxy.yaml
    sed -i "s#server: https://.*\$#server: https://$APISERVER_LB:6443#g" kube-proxy.yaml
    kubectl -n=kube-system delete configmap kube-proxy
    kubectl create -f kube-proxy.yaml
    # recreate kube-proxy pod to enable new configmap
    kubectl -n=kube-system delete po `kubectl -n=kube-system get pods -o name | grep kube-proxy`
}
public::main::node_up()
{
    public::common::nodeid

    public::common::install_package

    if [ "$LOAD_IMAGE" == "true" ];then
        public::docker::load_images node
    fi

    # public::nvidia::detect_gpu
    if [ "1" == "$GPU_ENABLED" ];then
        public::nvidia::setup_package
        public::nvidia::install_nvidia_driver $OS
        public::nvidia::enable_gpu_in_kube
        public::nvidia::install_nvidia_docker $OS
    else
        echo "Skip the step for non-GPU node"
    fi

    #########################################################################
    ##  deal with version ge 1.8.0, add additional arg --discovery-token-ca-cert-hash
    if [ -f /etc/kubeadm/kubejoin.sh ];then
        discover=$(cat /etc/kubeadm/kubejoin.sh)
    fi

    kubeadm join --node-name "$NODE_ID" --token $TOKEN $ENDPOINT $discover

    ## wait for localhost:6443 port api-proxy, return 60 OK, return 7 refuse
#    set +e
#    for ((i=0;i<60;i++))
#    do
#        public::common::log "wait for api-proxy [localhost:6443] up ..."
#        sleep 2
#        curl -sSL https://127.0.0.1:6443
#        code=$?
#        if [ $code -eq 60 ];then
#            public::common::log "api-proxy [localhost:6443] is up, we are good to go."
#            break
#        fi
#    done
#    set -e
#    if [ $code -ne 60 ];then
#        public::common::log "WARNING: failed to wait for api-proxy to be ready, cannot build up a HA cluster,
#            Your node would encount SINGLE MASTER FAILURE!"
#        public::common::log "Node has joined without high availability!"
#        exit 1
#    fi
    if [[ "$APISERVER_LB" != "1.1.1.1" ]];then
        if [[ -f /etc/kubernetes/kubelet.conf ]];then
            sed "/server: https:/d" /etc/kubernetes/kubelet.conf | \
                sed "/- cluster:/a \    server: https://`echo $APISERVER_LB|awk -F, '{print $1}'`:6443" >/etc/kubernetes/kubelet.conf
        fi
    fi

    systemctl restart kubelet
}


# run from the control-master. invoke the install of other two master.
public::master::deploy()
{
    if [ -z $HOSTS ];then
        public::common::log "--hosts must be provided in master_deploy ! eg. --hosts 192.168.0.1,192.168.0.2"
        exit 1
    fi

    public::common::master_env

    export MASTERS=${HOSTS//,/$'\n'}

    i=0 ; rm -rf pki.tar

    public::common::cloud_config

    mkdir -p /etc/kubernetes/pki/

    if [ "$CLUSTER_CA" != "" -a "$CLUSTER_CAKEY" != "" ];then

        echo "$CLUSTER_CA" \
            | sed "s/\\\n/ /g" \
            | sed "s/ CERTIFICATE/CERTIFICATE/g" \
            | tr " " "\n" \
            | sed "s/CERTIFICATE/ CERTIFICATE/g" > /etc/kubernetes/pki/ca.crt
        echo "$CLUSTER_CAKEY" \
            | sed "s/\\\n/ /g" \
            | sed "s/ RSA PRIVATE KEY/RSAPRIVATEKEY/g" \
            | tr " " "\n" \
            | sed "s/RSAPRIVATEKEY/ RSA PRIVATE KEY/g" > /etc/kubernetes/pki/ca.key
    fi

    if  [ "$CLIENT_CA" != "" ];then
        echo "$CLIENT_CA" \
            | sed "s/\\\n/ /g" \
            | sed "s/ CERTIFICATE/CERTIFICATE/g" \
            | tr " " "\n" \
            | sed "s/CERTIFICATE/ CERTIFICATE/g" > /etc/kubernetes/pki/client-ca.crt
    else
        touch /etc/kubernetes/pki/client-ca.crt
    fi

    for host in $MASTERS;
    do
        public::common::log "BEGAIN: init master:$host"
        ssh -e none root@$host "mkdir -p /etc/kubernetes/pki/dashboard"
        scp /etc/kubernetes/cloud-config root@$host:/etc/kubernetes/

        if [ -f /etc/kubernetes/pki/ca.crt ];then
            public::common::log "Using customized ca.crt. /etc/kubernetes/pki/ca.crt"
            scp /etc/kubernetes/pki/{ca.crt,ca.key,client-ca.crt} root@$host:/etc/kubernetes/pki/
        fi

        if [ "1" == "$GPU_ENABLED" ];then
            export GPU_FLAG="--gpu-enabled"
        else
            export GPU_FLAG=""
        fi

        if [ ! -f pki.tar ];then
            # upload script. Major master
            ssh -e none root@$host "export PKG_FILE_SERVER=$PKG_FILE_SERVER; \
                bash $PKG/$RUN/$RUN_VERSION/kubernetes.sh \
                --role master-major \
                --hosts $HOSTS \
                --extra-sans $EXTRA_SANS \
                --apiserver-lb $APISERVER_LB \
                --kube-version $KUBE_VERSION \
                --docker-version $DOCKER_VERSION \
                --load-images $LOAD_IMAGES \
                --etcd-hosts $ETCD_HOSTS \
                --key-id $KEY_ID \
                --key-secret $KEY_SECRET \
                $GPU_FLAG"

            scp root@$host:/etc/kubernetes/pki.tar .
        else
            ssh -e none root@$host "mkdir -p /etc/kubernetes/"
            cat pki.tar | ssh -e none root@$host "tar xv -C /etc/kubernetes/ "

            tar xf pki.tar ; TOKEN=$(cat pki/token.csv)
            # upload script. minor master
            ssh -e none root@$host "export PKG_FILE_SERVER=$PKG_FILE_SERVER;\
                bash $PKG/$RUN/$RUN_VERSION/kubernetes.sh \
                --role master-minor \
                --hosts $HOSTS \
                --extra-sans $EXTRA_SANS \
                --apiserver-lb $APISERVER_LB \
                --kube-version $KUBE_VERSION \
                --docker-version $DOCKER_VERSION \
                --load-images $LOAD_IMAGES \
                --etcd-hosts $ETCD_HOSTS \
                --token $TOKEN \
                --key-id $KEY_ID \
                --key-secret $KEY_SECRET \
                $GPU_FLAG"
        fi
        echo "END: join master:$host finish!"
    done
}

public::node::deploy()
{
    public::common::node_env

    export NODES=${HOSTS//,/$'\n'}

    if [ "1" == "$GPU_ENABLED" ];then
        export GPU_FLAG="--gpu-enabled"
    else
        export GPU_FLAG=""
    fi

    i=0 ;

    self=$(cd `dirname $0`; pwd)/`basename $0`
    for host in $NODES;
    do
        if [ -f /etc/kubeadm/kubejoin.sh ];then
            ssh -e none root@$host "mkdir -p /etc/kubeadm/"
            scp /etc/kubeadm/kubejoin.sh root@$host:/etc/kubeadm/
        fi
        public::common::log "BEGAIN: join nodes:$host"
        ssh -e none root@$host "export PKG_FILE_SERVER=$PKG_FILE_SERVER;\
            bash $PKG/$RUN/$RUN_VERSION/kubernetes.sh \
                --role node \
                --apiserver-lb $APISERVER_LB \
                --docker-version $DOCKER_VERSION \
                --kube-version $KUBE_VERSION \
                --load-images $LOAD_IMAGES \
                --token $TOKEN \
                --endpoint $ENDPOINT \
                $GPU_FLAG"

        echo "END: join node:$host finish!"
    done
}


public::common::common_env(){

    public::common::os_env

    if [ -z $KUBE_VERSION ];then
        export KUBE_VERSION=1.7.2
    fi
    if [ -z $DOCKER_VERSION ];then
        export DOCKER_VERSION=1.12.6
    fi
    if [ -z $EXTRA_SANS ];then
        export EXTRA_SANS=1.1.1.1
    fi
    if [ -z $LOAD_IMAGES ];then
        public::common::log "--load-images does not provided , set to default false"
        export LOAD_IMAGES="false"
    fi
    public::common::with_cidr
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

public::common::master_env()
{
    if [ -z $KEY_ID ];then
        public::common::log "--key-id must be provided!"
        exit 1
    fi
    if [ -z $KEY_SECRET ];then
        public::common::log "--key-secret must be provided!"
        exit 1
    fi
    if [ -z $APISERVER_LB ];then
        public::common::log "--apiserver-lb must be provided!"
        exit 1
    fi
    if [ -z $ETCD_HOSTS ];then
        public::common::log "--etcd-hosts must be provided! comma separated!"
        exit 1
    fi
    if [ -z $HOSTS ];then
        public::common::log "--host must be provided! comma separated! "
        exit 1
    fi
}

public::common::node_env()
{
    if [ -z $APISERVER_LB ];then
        public::common::log "--apiserver-lb must be provided!"
        exit 1
    fi
    if [ -z $TOKEN ];then
        public::common::log "--token must be provided! eg. abcdefg.abcdefghijklmnpqr"
        exit 1
    fi
    if [ -z $ENDPOINT ];then
        public::common::log "--endpoint must be provided! eg. 192.168.0.1:6443"
        exit 1
    fi
    if [ -z $HOSTS ];then
        public::common::log "--hosts must be provided ! eg. --hosts 192.168.0.1,192.168.0.2"
        exit 1
    fi
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

public::common::parse_args(){
    while [[ $# -gt 0 ]]
    do
    key="$1"

    case $key in
        --kube-version)
            export KUBE_VERSION=$2
            shift
        ;;
        --kubeadm-version)
            export KUBEADM_VERSION=$2
            shift
        ;;
        --docker-version)
            export DOCKER_VERSION=$2
            shift
        ;;
        --etcd-version)
            export ETCD_VERSION=$2
            shift
        ;;
        --role)
            export ROLE=$2
            shift
        ;;
        --key-id)
            export KEY_ID=$2
            shift
        ;;
        --key-secret)
            export KEY_SECRET=$2
            shift
        ;;
        --hosts)
            export HOSTS=$2
            shift
        ;;
	    --endpoint)
	        export ENDPOINT=$2
            shift
	    ;;
	    --token)
            export TOKEN=$2
	        shift
	    ;;
	    --extra-sans)
            export EXTRA_SANS=$2
	        shift
	    ;;
	    --apiserver-lb)
            export APISERVER_LB=$2
	        shift
	    ;;
	    --container-cidr)
            export CIDR=$2
	        shift
	    ;;
	    --etcd-hosts)
            export ETCD_HOSTS=$2
            shift
        ;;
        --load-images)
            export LOAD_IMAGES=$2
            shift
        ;;
        --cluster-ca)
            export CLUSTER_CA=$2
            shift
        ;;
        --cluster-cakey)
            export CLUSTER_CAKEY=$2
            shift
        ;;
        --client-ca)
            export CLIENT_CA=$2
            shift
        ;;
        --force)
            export FORCE="--force"
        ;;
        --gpu-enabled)
            export GPU_ENABLED=1
        ;;
        *)
            # unknown option
            public::common::log "unkonw option [$key]"
        ;;
    esac
    shift
    done
}

main()
{
    public::common::parse_args "$@"
    public::common::common_env

    case $ROLE in

    "source")
        public::common::log "source scripts"
        ;;
    "deploy-masters" )
        public::master::deploy
        ;;
    "master-major" )
        public::main::init_master "major"
        ;;
    "master-minor" )
        public::main::init_master "minor"
        ;;
    "deploy-nodes" )
        public::node::deploy
        ;;
    "node" )
        public::main::node_up
        ;;
    "destroy-node" )
        public::main::destroy_cluster
        ;;
    "node-down" )
        public::node::node_down
        ;;
    *)
        echo "usage: $0 m[master] | j[join] token | d[down] "
        echo "       $0 master to setup master "
        echo "       $0 join   to join master with token "
        echo "       $0 down   to tear all down ,inlude all data! so becarefull"
        echo "       unkown command $0 $@"
        ;;
    esac
}


main "$@"
