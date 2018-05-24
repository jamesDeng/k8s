阿里云 k8s 1.10 版本安装
===========================

安装过程比较心酸，由于是阿里云上安装但是并不想使用阿里云提供的一站式解决方案，这样需要自己和阿里云盘、NAS、LBS集成，看了不少阿里云集成k8s的文章，k8s版本都比较低而，其中踩了不少坑在这里总结一下安装过程


##服务器准备说明

1.安装的ECS系统为 centos 7.4，使用阿里VPC网络，打通所有ECS之间的SSH通道，并且能够实现公钥登录，避免安装过程中频繁输入密码。

2.使用 172.16.0.188 做为总控机，将本例中所以文件copy到/opt目录下

3.服务器列表：
|k8s-master|172.16.0.188|master and etcd
|---|---|---
|k8s-slave1|172.16.0.189|node and etcd
|---|---|---
|k8s-slave2|172.16.0.190|node and etcd


##安装etcd
使用了[玩转阿里云上Kubernetes 1.7.2 高可用部署](https://yq.aliyun.com/articles/221714?spm=a2c4e.11153940.blogcont562459.26.5a531c05GqTHSj)中的自动化部署脚本，但是由于并不支持高版本的etcd版本所以改了一下。

1.解压安装包，执行下面命令安装
./kuberun.sh --role deploy-etcd --hosts 172.16.0.188,172.16.0.189,172.16.0.190 --etcd-version v3.2.18

2.验证安装是成功
通过ps -eaf|grep etcd查看进程是否正常启动。

通过命令
etcdctl --endpoints=https://172.16.0.188:2379 \
        --ca-file=/var/lib/etcd/cert/ca.pem \
        --cert-file=/var/lib/etcd/cert/etcd-client.pem \
        --key-file=/var/lib/etcd/cert/etcd-client-key.pem \
        cluster-health

3.如发现有问题可执行命令撤消安装
./kuberun.sh --role destroy-etcd --hosts 172.16.0.188,172.16.0.189,172.16.0.190 --etcd-version v3.2.18

##安装docker

所有服务器都执行
curl -O https://yum.dockerproject.org/repo/main/centos/7/Packages/docker-engine-17.03.0.ce-1.el7.centos.x86_64.rpm
yum localinstall -y docker-engine-17.03.0.ce-1.el7.centos.x86_64.rpm

sed -i '$a net.bridge.bridge-nf-call-iptables = 1' /usr/lib/sysctl.d/00-system.conf
echo 1 > /proc/sys/net/bridge/bridge-nf-call-iptables
iptables -P FORWARD ACCEPT
sed -i "/ExecStart=/a\ExecStartPost=/usr/sbin/iptables -P FORWARD ACCEPT" /lib/systemd/system/docker.service
systemctl daemon-reload ; systemctl enable  docker.service; systemctl restart docker.service


##部署master

2.安装kubernetes master组件

组件为kubeadm、kubectl、kubectl、kubernetes-cni，由于有墙无法通过Yum源的方式安装，需要手动下载需要版本的rmp文件进行安装。

本例中提供 1.10版本rpm

安装包下载完成后执行
yum install socat
yum localinstall -y *

3.启动前准备

systemctl stop firewalld
systemctl disable firewalld

swapoff -a 
sed -i 's/.*swap.*/#&/' /etc/fstab

setenforce  0 
sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/sysconfig/selinux 
sed -i "s/^SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config 
sed -i "s/^SELINUX=permissive/SELINUX=disabled/g" /etc/sysconfig/selinux 
sed -i "s/^SELINUX=permissive/SELINUX=disabled/g" /etc/selinux/config  


3.由于墙docker 无法下载官方image,可以去阿里云docker仓库下载改成官方版本。

这里提供是1.10版本的docker image
docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/kube-apiserver-amd64:v1.10.0
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/kube-apiserver-amd64:v1.10.0 k8s.gcr.io/kube-apiserver-amd64:v1.10.0

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/kube-controller-manager-amd64:v1.10.0
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/kube-controller-manager-amd64:v1.10.0 k8s.gcr.io/kube-controller-manager-amd64:v1.10.0

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/kube-scheduler-amd64:v1.10.0
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/kube-scheduler-amd64:v1.10.0 k8s.gcr.io/kube-scheduler-amd64:v1.10.0

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/etcd-amd64:3.1.12
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/etcd-amd64:3.1.12 k8s.gcr.io/etcd-amd64:3.1.12

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/pause-amd64:3.1
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/pause-amd64:3.1 k8s.gcr.io/pause-amd64:3.1

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/k8s-dns-dnsmasq-nanny-amd64:1.14.5
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/k8s-dns-dnsmasq-nanny-amd64:1.14.5 k8s.gcr.io/k8s-dns-dnsmasq-nanny-amd64:1.14.5

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/k8s-dns-kube-dns-amd64:1.14.5
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/k8s-dns-kube-dns-amd64:1.14.5 k8s.gcr.io/k8s-dns-kube-dns-amd64:1.14.5

docker pull registry.cn-hangzhou.aliyuncs.com/google_containers/k8s-dns-sidecar-amd64:1.14.5
docker tag registry.cn-hangzhou.aliyuncs.com/google_containers/k8s-dns-sidecar-amd64:1.14.5 k8s.gcr.io/k8s-dns-sidecar-amd64:1.14.5

docker pull registry.cn-hangzhou.aliyuncs.com/google-containers/flannel:v0.9.0-amd64
docker tag registry.cn-hangzhou.aliyuncs.com/google-containers/flannel:v0.9.0-amd64 quay.io/coreos/flannel:v0.9.0-amd64


4.修改kubelet配置文件

vi /etc/systemd/system/kubelet.service.d/10-kubeadm.conf

#修改这一行
Environment="KUBELET_CGROUP_ARGS=--cgroup-driver=cgroupfs"
#添加对阿里云云盘支持
Environment="KUBELET_ALIYUN=--enable-controller-attach-detach=false"

#在执行命令添加 $KUBELET_ALIYUN
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_SYSTEM_PODS_ARGS $KUBELET_NETWORK_ARGS $KUBELET_DNS_ARGS $KUBELET_AUTHZ_ARGS $KUBELET_CADVISOR_ARGS $KUBELET_CGROUP_ARGS $KUBELET_CERTIFICATE_ARGS $KUBELET_EXTRA_ARGS $KUBELET_ALIYUN

执行
systemctl daemon-reload
systemctl enable kubelet


5.编写kubernetes 初始化配置文件
将配置文件保存在/etc/kubeadm/kubeadm.cfg

apiVersion: kubeadm.k8s.io/v1alpha1
kind: MasterConfiguration
networking:
  dnsDomain: cluster.local
  serviceSubnet: 10.19.0.0/16
  podSubnet: 10.16.0.0/16
kubernetesVersion: v1.10.0
etcd:
  endpoints:
  - https://172.16.0.188:2379
  - https://172.16.0.189:2379
  - https://172.16.0.190:2379
  caFile: /etc/kubernetes/pki/etcd/ca.pem
  certFile: /etc/kubernetes/pki/etcd/etcd-client.pem
  keyFile: /etc/kubernetes/pki/etcd/etcd-client-key.pem
apiServerCertSANs:
  - 172.16.0.188
  - 172.16.0.189
  - 172.16.0.190

6.执行初始化kubernetes 指令
mkdir -p /etc/kubernetes/pki/etcd/
cp -rf /var/lib/etcd/cert/{ca.pem,etcd-client.pem,etcd-client-key.pem} /etc/kubernetes/pki/etcd/
kubeadm init --config=/etc/kubeadm/kubeadm.cfg

如果执行成功，请根据提示执行相关命令，设置好环境变量
  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

如果执行失败，可以执行kubeadm reset回滚，修改配制后再执行上面的命令

7.执行DNS配制，解决无法解析公网DNS问题
kubectl create -f kube-dns.yaml

8.本例使用flannel作为网络组件

安装完成后，应用flannel.yml，文件安装包提供

kubectl apply -f flannel.yml

9.部署dashboard
kubectl create -f dashboard.yaml

获取token,通过令牌登陆
kubectl -n kube-system describe secret $(kubectl -n kube-system get secret | grep admin-user | awk '{print $1}')

通过firefox访问dashboard，输入token,即可登陆
https://IP:30000/#!/login

10.安装heapster
kubectl create -f kube-heapster/influxdb/

11.让master也运行pod（默认master不运行pod）
kubectl taint nodes --all node-role.kubernetes.io/master-

12.安装阿里云盘插件，参数阿里云官网教程

新建/etc/kubernetes/cloud-config文件,写入阿里云相关配制
vi /etc/kubernetes/cloud-config
{
    "global": {
     "accessKeyID": "阿里云accessKeyID",
     "accessKeySecret": "阿里云accessKeySecret"
   }
}

执行安装插件
kubectl create -f aliyun-disk.yaml
kubectl create -f aliyun-flex.yaml
kubectl create -f aliyun-nas-cotroller.yaml

13.安装 ingress-nginx

安装yaml全部为github拉取，只对 with-rbac.yaml 做了修改

#添加了使用Node网络，会使用部署的Node节点的80和443端口   
hostNetwork: true

执行
kubectl create -f ingress-nginx/

这里有个问题，nginx-ingress-controller只会运行在master节点上，暂时没有找到运行在Node上的办法，这样只能使用master节点上的80和443做为服务的入口点

执行可选，采用阿里云SLB方式做对外服务，映射 tcp 80 和443 到master节点


15.添加一个Node
请参照master安装
1)安装docker

2)安装kubeadm、kubectl、kubectl、kubernetes-cni

3)执行启动前准备

4)拉取docker image

5)修改kubelet配置文件，这里需要追加一处修改

#把执行命令中的 $KUBELET_NETWORK_ARGS 删除，不启用 network-plugin=cni
ExecStart=/usr/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_SYSTEM_PODS_ARGS $KUBELET_DNS_ARGS $KUBELET_AUTHZ_ARGS $KUBELET_CADVISOR_ARGS $KUBELET_CGROUP_ARGS $KUBELET_CERTIFICATE_ARGS $KUBELET_EXTRA_ARGS $KUBELET_ALIYUN

6)执行命令加入node

在初始化master的命令 kubeadm init --config=/etc/kubeadm/kubeadm.cfg 执行成功后会提示如下的加入命令，运作就加入node

kubeadm join 192.168.150.186:6443 --token b99a00.a144ef80536d4344 --discovery-token-ca-cert-hash sha256:f79b68fb698c92b9336474eb3bf184e847f967dc58a6296911892662b98b1315