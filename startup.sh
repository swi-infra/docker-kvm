#!/bin/bash

set -e

[ -n "$DEBUG" ] && set -x

# Create the kvm node (required --privileged)
if [ ! -e /dev/kvm ]; then
  set +e
  mknod /dev/kvm c 10 $(grep '\<kvm\>' /proc/misc | cut -f 1 -d' ')
  set -e
fi

QEMU=/usr/bin/qemu-system-x86_64

# If we were given arguments, override the default configuration
if [ $# -gt 0 ]; then
  exec $QEMU $@
  exit $?
fi

# mountpoint check
if [ ! -d /data ]; then
  if [ "${ISO:0:1}" != "/" ] || [ -z "$IMAGE" ]; then
    echo "/data not mounted: using -v to mount it"
    exit 1
  fi
fi

if [ -n "$CPU" ]; then
  echo "[cpu]"
  FLAGS_CPU="${CPU}"
  echo "parameter: ${FLAGS_CPU}"
else
  FLAGS_CPU="qemu64"
fi

if [ -n "$ISO" ]; then
  echo "[iso]"
  if [ "${ISO:0:1}" != "/" ] && [ "${ISO:0:4}" != "rbd:" ]; then
    basename=$(basename $ISO)
    if [ ! -f "/data/${basename}" ] || [ "$ISO_DOWNLOAD" != "0" ]; then
      wget -O- "$ISO" > /data/${basename}
    fi
    ISO=/data/${basename}
  fi
  FLAGS_ISO="-drive file=${ISO},media=cdrom,index=2"
  if [ "${ISO:0:4}" != "rbd:" ] && [ ! -f "$ISO" ]; then
    echo "ISO file not found: $ISO"
    exit 1
  fi
  echo "parameter: ${FLAGS_ISO}"
fi

if [ -n "$ISO2" ]; then
  echo "[iso2]"
  if [ "${ISO2:0:1}" != "/" ] && [ "${ISO2:0:4}" != "rbd:" ]; then
    basename=$(basename $ISO2)
    if [ ! -f "/data/${basename}" ] || [ "$ISO_DOWNLOAD" != "0" ]; then
      wget -O- "$ISO2" > /data/${basename}
    fi
    ISO2=/data/${basename}
  fi
  FLAGS_ISO2="-drive file=${ISO2},media=cdrom,index=3"
  if [ "${ISO2:0:4}" != "rbd:" ] && [ ! -f "$ISO2" ]; then
    echo "ISO2 file not found: $ISO2"
    exit 1
  fi
  echo "parameter: ${FLAGS_ISO2}"
fi

if [ $BIOS -eq 1 ]; then
  echo "[bios]"
  FLAGS_BIOS="-bios ${BIOS_IMAGE}"
  echo "parameter: ${FLAGS_BIOS}"
fi

echo "[disk image]"
if [ "$IMAGE_CREATE" == "1" ]; then
  qemu-img create -f ${IMAGE_FORMAT} ${IMAGE} ${IMAGE_SIZE}
elif [ "${IMAGE:0:4}" != "rbd:" ] && [ ! -f "$IMAGE" ]; then
  echo "IMAGE not found: ${IMAGE}"; exit 1;
fi
if [ "$DISK_DEVICE" == "scsi" ]; then
  FLAGS_DISK_IMAGE="-device virtio-scsi-pci,id=scsi0 -drive file=${IMAGE},if=none,id=hd,cache=${IMAGE_CACHE},discard=${IMAGE_DISCARD} -device scsi-hd,drive=hd,bus=scsi0.0,scsi-id=0,lun=0,id=scsi-disk0"
elif [ "$DISK_DEVICE" == "blk" ]; then
  FLAGS_DISK_IMAGE="-device virtio-blk-pci,scsi=off,addr=0x3,drive=drive-virtio-disk0,id=virtio-disk0,bootindex=1 -drive file=${IMAGE},if=none,id=drive-virtio-disk0,format=${IMAGE_FORMAT}"
else
  FLAGS_DISK_IMAGE="-drive file=${IMAGE},if=${DISK_DEVICE},cache=${IMAGE_CACHE},format=${IMAGE_FORMAT},index=1"
fi
echo "parameter: [$DISK_DEVICE] ${FLAGS_DISK_IMAGE}"

if [ -n "$FLOPPY" ]; then
  echo "[floppy image]"
  FLAGS_FLOPPY_IMAGE="-fda ${FLOPPY}"
  echo "parameter: ${FLAGS_FLOPPY_IMAGE}"
fi

echo "[network]"
if [ "$NETWORK" == "bridge" ]; then
  NETWORK_BRIDGE="${NETWORK_BRIDGE:-docker0}"
  hexchars="0123456789ABCDEF"
  NETWORK_MAC="${NETWORK_MAC:-$(echo 00:F0$(for i in {1..8} ; do echo -n ${hexchars:$(( $RANDOM % 16 )):1} ; done | sed -e 's/\(..\)/:\1/g'))}"
  echo "mac address: ${NETWORK_MAC}"
  mkdir -p /etc/qemu
  echo allow $NETWORK_BRIDGE > /etc/qemu/bridge.conf
  FLAGS_NETWORK="-netdev bridge,br=${NETWORK_BRIDGE},id=net0 -device virtio-net,romfile=${NETWORK_ROMFILE},netdev=net0,mac=${NETWORK_MAC}"
elif [ "$NETWORK" == "tap" ]; then
  IFACE=eth0
  TAP_IFACE=tap0
  IP=`ip addr show dev $IFACE | grep "inet " | awk '{print $2}' | cut -f1 -d/`
  NAMESERVER=`grep nameserver /etc/resolv.conf | cut -f2 -d ' '`
  NAMESERVERS=`echo ${NAMESERVER[*]} | sed "s/ /,/g"`
  NETWORK_IP="${NETWORK_IP:-$(echo 172.$((RANDOM%(31-16+1)+16)).$((RANDOM%256)).$((RANDOM%(254-2+1)+2)))}"
  NETWORK_SUB=`echo $NETWORK_IP | cut -f1,2,3 -d\.`
  NETWORK_GW="${NETWORK_GW:-$(echo ${NETWORK_SUB}.1)}"
  tunctl -t $TAP_IFACE
  dnsmasq --user=root \
    --dhcp-range=$NETWORK_IP,$NETWORK_IP \
    --dhcp-option=option:router,$NETWORK_GW \
    --dhcp-option=option:dns-server,$NAMESERVERS
  ifconfig $TAP_IFACE $NETWORK_GW up
  iptables -t nat -A POSTROUTING -o $IFACE -j MASQUERADE
  iptables -I FORWARD 1 -i $TAP_IFACE -j ACCEPT
  iptables -I FORWARD 1 -o $TAP_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
  if [ "$VNC" == "tcp" ]; then
    iptables -t nat -A PREROUTING -p tcp -d $IP ! --dport `expr 5900 + $VNC_ID` -j DNAT --to-destination $NETWORK_IP
    iptables -t nat -A PREROUTING -p udp -d $IP -j DNAT --to-destination $NETWORK_IP
    iptables -t nat -A PREROUTING -p icmp -d $IP -j DNAT --to-destination $NETWORK_IP
  else
    iptables -t nat -A PREROUTING -d $IP -j DNAT --to-destination $NETWORK_IP
  fi
  FLAGS_NETWORK="-netdev tap,id=net0,ifname=tap0,vhost=on,script=no,downscript=no -device virtio-net-pci,netdev=net0"
elif [ "$NETWORK" == "macvtap" ]; then
  NETWORK_IF="${NETWORK_IF:-eth0}"
  NETWORK_BRIDGE="${NETWORK_BRIDGE:-vtap0}"
  hexchars="0123456789ABCDEF"
  NETWORK_MAC="${NETWORK_MAC:-$(echo 00:F0$(for i in {1..8} ; do echo -n ${hexchars:$(( $RANDOM % 16 )):1} ; done | sed -e 's/\(..\)/:\1/g'))}"
  echo "mac address: ${NETWORK_MAC}"
  set +e
  ip link add link $NETWORK_IF name $NETWORK_BRIDGE address $NETWORK_MAC type macvtap mode bridge
  if [[ $? -ne 0 ]]; then
    echo "Warning! Bridge interface already exists"
  fi
  set -e
  FLAGS_NETWORK="-netdev tap,fd=3,id=net0,vhost=on -net nic,vlan=0,netdev=net0,macaddr=$NETWORK_MAC,model=virtio"
  exec 3<> /dev/tap`cat /sys/class/net/$NETWORK_BRIDGE/ifindex`
  ip link set $NETWORK_BRIDGE up
  if [ ! -z "$NETWORK_IF2" ]; then
    NETWORK_BRIDGE2="${NETWORK_BRIDGE2:-vtap1}"
    NETWORK_MAC2="${NETWORK_MAC2:-$(echo 00:F0$(for i in {1..8} ; do echo -n ${hexchars:$(( $RANDOM % 16 )):1} ; done | sed -e 's/\(..\)/:\1/g'))}"
    set +e
    ip link add link $NETWORK_IF2 name $NETWORK_BRIDGE2 address $NETWORK_MAC2 type macvtap mode bridge
    if [[ $? -ne 0 ]]; then
      echo "Warning! Bridge interface 2 already exists"
    fi
    set -e
    FLAGS_NETWORK="${FLAGS_NETWORK} -netdev tap,fd=4,id=net1,vhost=on -net nic,vlan=1,netdev=net1,macaddr=$NETWORK_MAC2,model=virtio"
    exec 4<> /dev/tap`cat /sys/class/net/$NETWORK_BRIDGE2/ifindex`
    ip link set $NETWORK_BRIDGE2 up
  fi
else
  NETWORK="user"
  REDIR=""
  if [ ! -z "$TCP_PORTS" ]; then
    OIFS=$IFS
    IFS=","
    for port in $TCP_PORTS; do
      REDIR+="-redir tcp:${port}::${port} "
    done
    IFS=$OIFS
  fi

  if [ ! -z "$UDP_PORTS" ]; then
    OIFS=$IFS
    IFS=","
    for port in $UDP_PORTS; do
      REDIR+="-redir udp:${port}::${port} "
    done
    IFS=$OIFS
  fi
  FLAGS_NETWORK="-net nic,model=virtio -net user ${REDIR}"
fi
echo "Using ${NETWORK}"
echo "parameter: ${FLAGS_NETWORK}"

echo "[remote]"

# Spice
if [ "$SPICE" == "tcp" ]; then
  SPICE_ID=${SPICE_ID:-$VNC_ID}
  SPICE_PORT=${SPICE_PORT:-$((5900 + $SPICE_ID))}
  FLAGS_SPICE_PWD=",disable-ticketing"
  if [ -n "$SPICE_PASSWORD" ]; then
    FLAGS_SPICE_PWD=",password=$SPICE_PASSWORD"
  fi
  FLAGS_REMOTE_ACCESS="-vga qxl -spice port=${SPICE_PORT}${FLAGS_SPICE_PWD} -device virtio-serial-pci -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0 -chardev spicevmc,id=spicechannel0,name=vdagent"
elif [ "$SPICE" == "sock" ]; then
  FLAGS_REMOTE_ACCESS="-vga qxl -spice unix,addr=${SPICE_SOCK},disable-ticketing -device virtio-serial-pci -device virtserialport,chardev=spicechannel0,name=com.redhat.spice.0 -chardev spicevmc,id=spicechannel0,name=vdagent"

# VNC
elif [ "$VNC" == "tcp" ]; then
  FLAGS_REMOTE_ACCESS="-vnc ${VNC_IP}:${VNC_ID}"
elif [ "$VNC" == "reverse" ]; then
  FLAGS_REMOTE_ACCESS="-vnc ${VNC_IP}:${VNC_PORT},reverse"
elif [ "$VNC" == "sock" ]; then
  FLAGS_REMOTE_ACCESS="-vnc unix:${VNC_SOCK}"

# No graphics
else
  FLAGS_REMOTE_ACCESS="-nographic"
fi
echo "parameter: ${FLAGS_REMOTE_ACCESS}"

if [ $CONSOLE -eq 1 ]; then
  FLAGS_CONSOLE="-serial stdio"
  echo "parameter: ${FLAGS_CONSOLE}"
fi

if [ -n "$BOOT" ]; then
  echo "[boot]"
  FLAGS_BOOT="-boot ${BOOT}"
  echo "parameter: ${FLAGS_BOOT}"
fi

if [ -n "$KEYBOARD" ]; then
  echo "[keyboard]"
  FLAGS_KEYBOARD="-k ${KEYBOARD}"
  echo "parameter: ${FLAGS_KEYBOARD}"
fi

if [ -n "$USB" ]; then
  echo "[usb]"
  FLAGS_USB="-usb -usbdevice tablet"
  echo "parameter: ${FLAGS_USB}"
fi

if [ -n "$MONITOR" ]; then
  echo "[monitor]"
  if [ "$MONITOR" == "telnet" ]; then
    MONITOR_HOST=${MONITOR_HOST:-localhost}
    MONITOR_PORT=${MONITOR_PORT:-4444}
    FLAGS_MONITOR="-chardev socket,id=mon0,host=$MONITOR_HOST,port=$MONITOR_PORT,server,nowait -mon chardev=mon0,mode=readline,pretty=on"
  fi
fi

if [ -n "$FLAGS_DEBUG" ]; then
    touch /tmp/qemu.log
    tail -f /tmp/qemu.log &
fi

if [ "$BALLOON" == "1" ]; then
  echo "[balloon]"
  FLAGS_BALLOON="-device virtio-balloon"
  echo "parameter: ${FLAGS_BALLOON}"
fi

if [ -n "$FLAGS_OTHER" ]; then
  echo "[other]"
  echo "parameters: ${FLAGS_OTHER}"
fi

${QEMU} -version 2>&1

set -x

exec ${QEMU} ${FLAGS_REMOTE_ACCESS} \
  -k en-us \
  -machine ${MACHINE} \
  -m ${RAM} \
  -smp ${SMP} \
  -cpu ${FLAGS_CPU} \
  -no-shutdown \
  -enable-kvm \
  -name ${HOSTNAME} \
  ${FLAGS_DEBUG} \
  ${FLAGS_MONITOR} \
  ${FLAGS_BALLOON} \
  ${FLAGS_DISK_IMAGE} \
  ${FLAGS_FLOPPY_IMAGE} \
  ${FLAGS_CONSOLE} \
  ${FLAGS_ISO} \
  ${FLAGS_ISO2} \
  ${FLAGS_NETWORK} \
  ${FLAGS_KEYBOARD} \
  ${FLAGS_USB} \
  ${FLAGS_BOOT} \
  ${FLAGS_BIOS} \
  ${FLAGS_OTHER}
