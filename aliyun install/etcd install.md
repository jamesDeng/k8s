安装etcd

1.引用阿里云贴的脚本进行修改，去掉下载etcd安装包的动作，改用手动下载安装包（贴子原处https://yq.aliyun.com/articles/221714?spm=a2c4e.11153940.blogcont562459.26.292f1c05pQxXi3）

2.解压安装包，执行下面命令安装
./kuberun.sh --role deploy-etcd --hosts 172.16.0.188,172.16.0.189,172.16.0.190 --etcd-version v3.2.18

3.验证安装是成功
通过ps -eaf|grep etcd查看进程是否正常启动。

通过命令
etcdctl --endpoints=https://172.16.0.188:2379 \
        --ca-file=/var/lib/etcd/cert/ca.pem \
        --cert-file=/var/lib/etcd/cert/etcd-client.pem \
        --key-file=/var/lib/etcd/cert/etcd-client-key.pem \
        cluster-health

4.撤消安装
./kuberun.sh --role destroy-etcd --hosts 172.16.0.188,172.16.0.189,172.16.0.190 --etcd-version v3.2.18