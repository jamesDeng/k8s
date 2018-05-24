#!/usr/bin/env bash

OSS_NVIDIA_URL=http://aliyuncontainerservice.oss-cn-hangzhou.aliyuncs.com
# NVIDIA_VERSION=v1.0.1

public::nvidia::setup_package(){
    set +e
    if [ -z $NVIDIA_VERSION ];then
        export NVIDIA_VERSION=v1.0.1
    fi
    public::common::prepare_package nvidia $NVIDIA_VERSION
    dir=pkg/nvidia/$NVIDIA_VERSION/common
    mv $dir/* .
    set -e
}


public::nvidia::install_nvidia_driver(){
    #blacklist nouveau
    set +e
    if  `which nvidia-smi > /dev/null 2>&1` ; then
          return
    fi
    echo 'blacklist nouveau' >> /etc/modprobe.d/disable-nouveau.conf
    # dracut /boot/initramfs-$(uname -r).img $(uname -r) --force
    rmmod nouveau || true

    if [ "$1" == "CentOS" ];then
        yum install -y dracut gcc kernel-devel-`uname -r`
        if [ ! -f kernel-devel-`uname -r`.rpm ];then
            curl --retry 5 -sSL $OSS_NVIDIA_URL/hpc/centos/kernel/kernel-devel-`uname -r`.rpm -o kernel-devel-`uname -r`.rpm
            yum localinstall -y kernel-devel-`uname -r`.rpm
        fi
    else
        apt install -y linux-headers-`uname -r`    
    fi
    set -e
    if [ ! -f NVIDIA-Linux-x86_64-375.39.run ];then
        curl --retry 5 -sSL $OSS_NVIDIA_URL/hpc/nvidia/NVIDIA-Linux-x86_64-375.39.run -o NVIDIA-Linux-x86_64-375.39.run
    fi
    sh NVIDIA-Linux-x86_64-375.39.run -a -s -q

    # warm up GPU before starting kubelet
    nvidia-smi -pm 1 || true
    nvidia-smi -acp 0 || true
    nvidia-smi --auto-boost-default=0 || true
    nvidia-smi --auto-boost-permission=0 || true
    nvidia-modprobe -u -c=0 -m || true

    # make rc.local with warming up GPU
    echo 'nvidia-smi -pm 1 || true' >> /etc/rc.d/rc.local
    echo 'nvidia-smi -acp 0 || true' >> /etc/rc.d/rc.local
    echo 'nvidia-smi --auto-boost-default=0 || true' >> /etc/rc.d/rc.local
    echo 'nvidia-smi --auto-boost-permission=0 || true' >> /etc/rc.d/rc.local
    echo 'nvidia-modprobe -u -c=0 -m || true' >> /etc/rc.d/rc.local
    chmod +x /etc/rc.d/rc.local
}

public::nvidia::install_nvidia_docker(){
    set +e
    sleep 3
    if  `which nvidia-docker > /dev/null 2>&1` ; then
          return
    fi
    if [ "$1" == "CentOS" ];then
        if [ ! -f nvidia-docker.rpm ];then
            curl -L $OSS_NVIDIA_URL/hpc/nvidia/nvidia-docker-1.0.1-1.x86_64.rpm -o nvidia-docker.rpm
        fi

        yum -y -q --nogpgcheck localinstall nvidia-docker.rpm
        systemctl enable nvidia-docker
    else
        if [ ! -f nvidia-docker.deb ];then
            curl -L $OSS_NVIDIA_URL/hpc/nvidia/nvidia-docker_1.0.1-1_amd64.deb -o nvidia-docker.deb
        fi
        dpkg -i nvidia-docker.deb
        systemctl enable nvidia-docker   
    fi

    service nvidia-docker restart
    docker volume create --name=nvidia_driver_`nvidia-smi |grep Driver.Version|awk '{print $6}'` -d nvidia-docker
    set -e
}

public::nvidia::enable_gpu_in_kube(){
    sed -i '/^ExecStart=$/iEnvironment="KUBELET_EXTRA_ARGS=--feature-gates=Accelerators=true"' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
    systemctl daemon-reload
    systemctl restart kubelet
}