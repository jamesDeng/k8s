# 集群部署规范
集群部署需要登录到各个机器上执行初始化及更新脚本，登录采用SSH，密码输入采用expect或者配置公钥登录。

使用一台机器作为发布机，这台机器可以是其中一个节点也可以是单独的发布机。

## 命令行接口

使用kubernetes.sh部署k8s集群.

### 部署master节点

**前置条件：** 依赖于事先部署好一套ETCD集群。

**参数：**

- --action          deploy-masters, deploy-workers, destroy-nodes
- --hosts           标识部署的目标机器，用逗号分隔。 例如--hosts 192.168.0.1,192.168.0.1
- --etcd-hosts      指定etcd集群的位置
- --apiserver-lb    指定apiserver前的LoadBalancer地址。用逗号分隔
- --extra-sans      指定任何想要打入到apiserver证书里面的CN。用逗号分隔。
- --key-id          公有云的accesskey
- --key-secret      公有云的accesskeysecret
- --docker-version  指定安装的docker版本，默认值1.12.6
- --kube-version    指定安装的kubernetes版本，默认值1.7.2
- --gpu-enabled     是否支持GPU调度，含有此参数表明支持

**示例：**
```
./kubernetes.sh \
        --action deploy-masters \
        --hosts 192.168.0.1,192.168.0.2,192.168.0.3 \
        --etcd-hosts 192.168.0.1,192.168.0.2,192.168.0.3 \
        --apiserver-lb 1.1.1.1 \
        --extra-sans 3.3.3.3,4.4.4.4 \
        --key-id abcdefghijk \
        --key-secret abcdfidkkllll

```


### 部署worker节点
**前置条件：**

- 依赖于事先部署好一套ETCD集群。
- 依赖于首先部署好master节点。

**参数：**

- --action          deploy-workers
- --hosts           标识部署的目标机器，用逗号分隔。 例如--hosts 192.168.0.1,192.168.0.1
- --etcd-hosts      指定etcd集群的位置
- --apiserver-lb    指定apiserver前的LoadBalancer地址。用逗号分隔
- --docker-version  指定安装的docker版本，默认值1.12.6
- --kube-version    指定安装的kubernetes版本，默认值1.7.2
- --gpu-enabled     是否支持GPU调度，含有此参数表明支持

**示例：**

```
./kubernetes.sh \
        --role deploy-workers \
        --hosts 192.168.142.188,192.168.142.189 \
        --etcd-hosts 192.168.0.1,192.168.0.2,192.168.0.3 \
        --apiserver-lb 1.1.1.1 \
        --token e44f20.c1788298ee2bd20a \
        --endpoint 192.168.0.3:6443
```

### 清理节点环境

当部署出错的时候需要先清理一遍安装环境，然后重新执行部署动作。

**前置条件：**
- 无

**参数：**

- --action          destroy-nodes
- --hosts           标识部署的目标机器，用逗号分隔。 例如--hosts 192.168.0.1,192.168.0.1

**示例：**
```
./kubernetes.sh \
        --role destroy-nodes \
        --hosts 192.168.142.188,192.168.142.189 \
```
