#!/usr/bin/env bash

set -e
set -x

## -==========================================================================================================================

source $(cd `dirname ${BASH_SOURCE}`; pwd)/common.sh

public::etcd::install_etcd()
{
    if [ -z $ETCD_VERSION ];then
        public::common::log "ETCD_VERSION must be provided ! --version v3.0.17 "
        exit 1
    fi
    #public::common::prepare_package etcd $ETCD_VERSION

    set +e
    ETCD_DIR=/opt/etcd-$ETCD_VERSION
	mkdir -p $ETCD_DIR /var/lib/etcd /etc/etcd;
	groupadd -r etcd; useradd -r -g etcd -d /var/lib/etcd -s /sbin/nologin -c "etcd user" etcd;
	chown -R etcd:etcd /var/lib/etcd
	if [ ! -f /root/etcd.service.tmp ];then
	    public::common::log "Error: Pls define /root/etcd.service.tmp for etcd."
	    exit 1
	fi
	mv /root/etcd.service.tmp /lib/systemd/system/etcd.service

	####

	tar xzf $PKG/etcd/$ETCD_VERSION/rpm/etcd-$ETCD_VERSION-linux-amd64.tar.gz --strip-components=1 -C $ETCD_DIR;
	cp -rf $PKG/etcd/$ETCD_VERSION/rpm/{cfssl,cfssljson} /usr/bin/
	chmod +x /usr/bin/{cfssl,cfssljson}
	ln -sf $ETCD_DIR/etcd /usr/bin/etcd; ln -sf $ETCD_DIR/etcdctl /usr/bin/etcdctl;
    #cp -rf
	etcd --version
	public::common::log "etcd binary installed. Start to enable etcd"
	systemctl enable etcd; systemctl start etcd; sleep 2
	#echo etcdctl ls --endpoints=http://192.168.1.179:2379
	set -e
}

public::etcd::down()
{
    set +e
	systemctl disable etcd ; systemctl stop etcd
	rm -rf /var/lib/etcd /usr/lib/systemd/system/etcd.service
	set -e
}

public::etcd::service()
{
    cat << EOT > etcd.service.tmp
[Unit]
Description=etcd service
After=network.target

[Service]
#Type=notify
WorkingDirectory=/var/lib/etcd/
User=etcd
ExecStart=/usr/bin/etcd --data-dir=data.etcd --name ${THIS_NAME} \
	--client-cert-auth --trusted-ca-file=/var/lib/etcd/cert/ca.pem \
	--cert-file=/var/lib/etcd/cert/etcd-server.pem --key-file=/var/lib/etcd/cert/etcd-server-key.pem \
	--peer-client-cert-auth --peer-trusted-ca-file=/var/lib/etcd/cert/peer-ca.pem \
	--peer-cert-file=/var/lib/etcd/cert/${THIS_NAME}.pem --peer-key-file=/var/lib/etcd/cert/${THIS_NAME}-key.pem \
	--initial-advertise-peer-urls https://${THIS_IP}:2380 --listen-peer-urls https://${THIS_IP}:2380 \
	--advertise-client-urls https://${THIS_IP}:2379 --listen-client-urls https://${THIS_IP}:2379 \
	--initial-cluster ${CLUSTER} \
	--initial-cluster-state ${CLUSTER_STATE} --initial-cluster-token ${TOKEN}
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOT
}

public::etcd::genssl()
{
    mkdir -p cert/;dir=cert
    echo '{"CN":"CA","key":{"algo":"rsa","size":2048}}' | \
        cfssl gencert -initca - | cfssljson -bare $dir/ca -
    echo '{"signing":{"default":{"expiry":"438000h","usages":["signing","key encipherment","server auth","client auth"]}}}' > $dir/ca-config.json

    export ADDRESS=$HOSTS,ext1.example.com,coreos1.local,coreos1
    export NAME=etcd-server
    echo '{"CN":"'$NAME'","hosts":[""],"key":{"algo":"rsa","size":2048}}' | \
        cfssl gencert -config=$dir/ca-config.json -ca=$dir/ca.pem -ca-key=$dir/ca-key.pem -hostname="$ADDRESS" - | cfssljson -bare $dir/$NAME
    export ADDRESS=
    export NAME=etcd-client
    echo '{"CN":"'$NAME'","hosts":[""],"key":{"algo":"rsa","size":2048}}' | \
        cfssl gencert -config=$dir/ca-config.json -ca=$dir/ca.pem -ca-key=$dir/ca-key.pem -hostname="$ADDRESS" - | cfssljson -bare $dir/$NAME

	# gen peer-ca
	echo '{"CN":"Peer-CA","key":{"algo":"rsa","size":2048}}' | cfssl gencert -initca - | cfssljson -bare $dir/peer-ca -
    echo '{"signing":{"default":{"expiry":"438000h","usages":["signing","key encipherment","server auth","client auth"]}}}' > $dir/peer-ca-config.json
    i=0
	for host in $ETCD_HOST;
	do
		((i=i+1))
        export MEMBER=${host}-name-$i
		echo '{"CN":"'${MEMBER}'","hosts":[""],"key":{"algo":"rsa","size":2048}}' | \
		    cfssl gencert -ca=$dir/peer-ca.pem -ca-key=$dir/peer-ca-key.pem -config=$dir/peer-ca-config.json -profile=peer \
		    -hostname="$host,${MEMBER}.local,${MEMBER}" - | cfssljson -bare $dir/${MEMBER}
	done;
}

public::etcd::deploy()
{
    if [ -z $ETCD_VERSION ];then
        public::common::log "ETCD_VERSION must be provided ! --version v3.0.17 "
        exit 1
    fi
    if [ -z $HOSTS ];then
        public::common::log "Target Host must be provided ! --hosts a,b,c "
        exit 1
    fi

    #public::common::prepare_package etcd $ETCD_VERSION

    cp -rf $PKG/etcd/$ETCD_VERSION/rpm/{cfssl,cfssljson} /usr/bin/ ; chmod +x /usr/bin/{cfssl,cfssljson}

    export ETCD_HOST=${HOSTS//,/$'\n'}

    export TOKEN=`uuidgen` CLUSTER_STATE=new
    echo   $TOKEN>etcd.token.csv

    i=0
    self=$(cd `dirname $0`; pwd)/`basename $0`

    # For machine 1
    for h in $ETCD_HOST;
    do
        ((i=i+1))
        CLUSTER="${CLUSTER}${h}-name-$i=https://${h}:2380,"
        ssh -e none root@$host "bash $PKG/$RUN/$RUN_VERSION/etcd.sh --role down --hosts $HOSTS --version $ETCD_VERSION"
    done

    public::etcd::genssl ; tar cvf etcd-cert.tar cert
    CLUSTER=${CLUSTER%,*}
    i=0
    for host in $ETCD_HOST;
    do
        public::common::log "BEGAIN:$self,$host, $THIS_NAME, $THIS_IP"
        ((i=i+1))
        export THIS_NAME=${host}-name-$i THIS_IP=${host}

        public::etcd::service

        scp etcd.service.tmp root@$host:/root/etcd.service.tmp
	    scp etcd-cert.tar root@$host:/root/etcd-cert.tar
        ssh -e none root@$host 'mkdir -p /var/lib/etcd ; tar xf etcd-cert.tar -C /var/lib/etcd/'
        ssh -e none root@$host "export PKG_FILE_SERVER=$PKG_FILE_SERVER; bash $PKG/$RUN/$RUN_VERSION/etcd.sh --role up --hosts $HOSTS --version $ETCD_VERSION"
    done
}

public::etcd::destroy(){

    if [ -z $HOSTS ];then
        public::common::log "Target Host must be provided ! --hosts a,b,c "
        exit 1
    fi
    export ETCD_HOST=${HOSTS//,/$'\n'}

    self=$(cd `dirname $0`; pwd)/`basename $0`

    # For machine 1
    for host in $ETCD_HOST;
    do
        ssh -e none root@$host "bash $PKG/$RUN/$RUN_VERSION/etcd.sh --role down --hosts $HOSTS --version $ETCD_VERSION"
    done
}

main()
{

    while [[ $# -gt 1 ]]
    do
    key="$1"

    case $key in

        --role)
            export ROLE=$2
            shift
            ;;
        --version)
            export ETCD_VERSION=$2
            shift
            ;;
	    --hosts)
            export HOST=$2
	        shift
	        ;;
        *)
            echo "unkonw option [$key]"
            ;;
    esac
    shift
    done

    case $ROLE in

    "source")
        public::common::log "source scripts"
        ;;
    "deploy" )
        public::etcd::deploy
        ;;
    "destroy" )
        public::etcd::destroy
        ;;
    "up" )
        public::etcd::install_etcd
        ;;
    "down" )
        public::etcd::down
        ;;
    *)
        echo "usage: $0 --role deploy --hosts 192.168.0.1,192.168.0.2,192.168.0.3 "
        echo "       $0 --role destroy --hosts 192.168.0.1,192.168.0.2,192.168.0.3"

        ;;
    esac
}
main "$@"
