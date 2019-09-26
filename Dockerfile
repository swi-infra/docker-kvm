FROM alpine
MAINTAINER CoRfr <broussel@sierrawireless.com>

RUN \
  apk add --no-cache qemu-system-x86_64 qemu-img bridge-utils dnsmasq iproute2 wget iptables net-tools bash busybox-extras

ENV MACHINE q35
ENV RAM 2048
ENV SMP 1
ENV CPU qemu64
ENV DISK_DEVICE scsi
ENV IMAGE /data/disk-image
ENV IMAGE_FORMAT qcow2
ENV IMAGE_SIZE 10G
ENV IMAGE_CACHE none
ENV IMAGE_DISCARD unmap
ENV IMAGE_CREATE 0
ENV ISO_DOWNLOAD 0
ENV NETWORK tap
ENV SPICE none
ENV VNC none
ENV VNC_IP ""
ENV VNC_ID 0
ENV VNC_PORT 5500
ENV VNC_SOCK /data/vnc.sock
ENV TCP_PORTS ""
ENV UDP_PORTS ""
ENV MONITOR ""
ENV CONSOLE 1
ENV BIOS 1
ENV BIOS_IMAGE /opt/qemu/seabios-no-usb.bin

ADD startup.sh /
ADD seabios-no-usb.bin /opt/qemu/

EXPOSE 22 4444 5900

VOLUME /data

ENTRYPOINT ["/startup.sh"]
