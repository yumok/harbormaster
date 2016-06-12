#!/bin/bash

# Move files from container's staging directory to the build directory
rsync -avc /source/ ${BUILD_DIRECTORY} 

cd ${BUILD_DIRECTORY}
cp -a cobbler/var/* /var/lib/cobbler/

# Pass along proxy settings to the container's cobbler
sed -i 's@proxy_url_ext: ""@proxy_url_ext: "'${HTTP_PROXY}'"@g' /etc/cobbler/settings

# DO THE OTHER SEDDY THINGS.
REPLACE_VARS='$K8S_CLEAN_BUILD:$K8S_VERSION:$K8S_CLUSTER_IP_RANGE:$K8S_NODE_POD_CIDR:$COBBLER_IP:$NETWORK_ROUTER:$NETWORK_DOMAIN:$NETWORK_BOOTP_START:$NETWORK_BOOTP_END:$NETWORK_NETMASK:$NETWORK_SUBNET:$NETWORK_UPSTREAMDNS:$NETWORK_DNS_REVERSE:$NUM_MASTERS:$NETWORK_NETMASK2:$HTTP_PROXY'

envsubst "$REPLACE_VARS" < templates/ks.cfg > ks.cfg
envsubst "$REPLACE_VARS" < templates/cobbler/etc/dhcp.template.tmpl > cobbler/etc/dhcp.template
envsubst "$REPLACE_VARS" < templates/cobbler/etc/named.template.tmpl > cobbler/etc/named.template
envsubst "$REPLACE_VARS" < templates/cobbler/etc/settings.tmpl > cobbler/etc/settings

# Resolve provisioning templates

# Start Cobbler
httpd
cobblerd

# Download latest boot loaders
cobbler get-loaders --force
cp -a /var/lib/cobbler/loaders cobbler/var/


# Make k8s packages
cd kubernetes-distro-packages
./build_kubernetes.sh
./build_etcd.sh
cd ..
 
# Create partial mirror for cobbler installation
mkdir -p ./cobbler-repo
repotrack -a x86_64 -p ./cobbler-repo/ ipxe-bootimgs cobbler cobbler-web perl-LockFile-Simple perl-IO-Compress perl-Compress-Raw-Zlib perl-Digest-MD5 perl-Digest-SHA perl-Net-INET6Glue perl-LWP-Protocol-https
createrepo cobbler-repo/

# Adds debian packages to Kubernetes repo
mkdir -p ubuntu/repos/kubernetes
reprepro -b ubuntu/repos/kubernetes includedeb xenial ${BUILD_DIRECTORY}/kubernetes-distro-packages/kubernetes/builds/*.deb
reprepro -b ubuntu/repos/kubernetes includedeb xenial ${BUILD_DIRECTORY}/kubernetes-distro-packages/etcd/builds/*.deb

# Partial mirror of main
mkdir main-mirror
cd main-mirror
for i in `cat ../ubuntu/repos/main/downloadlist` ; do curl -O $i ; done
cd ..
reprepro -b ubuntu/repos/main includedeb xenial ${BUILD_DIRECTORY}/main-mirror/*.deb

# Mirror Universe, 60 gigs...
#./cobbler/bin/debmirror -v -p --no-check-gpg  -h archive.ubuntu.com -r ubuntu -d xenial -s universe -a amd64 --method=http --nosource ubuntu/repos/universe

# Mirror just what we need from universe, this can be revised/updated by using ubuntu_required_packages.sh
#./cobbler/bin/debmirror -v -p  --no-check-gpg -h archive.ubuntu.com --i18n -r ubuntu -d xenial -s universe -a amd64 --method=http --nosource ubuntu/repos/universe --exclude='/*'  --include=ceph-fs-common --include=gir1.2-libosinfo-1.0  --include=koan   --include=libosinfo-1.0-0  --include=python-ethtool --include=python-koan  --include=virtinst --include='/Translation*'
#./cobbler/bin/debmirror -v -p --no-check-gpg -h archive.ubuntu.com --i18n -r ubuntu -d xenial -s universe -a amd64 --method=http --nosource ubuntu/repos/universe --exclude='/*'  --include=ceph-fs-common --include=gir1.2-libosinfo-1.0  --include=koan   --include=libosinfo-1.0-0  --include=python-ethtool --include=python-koan  --include=virtinst
# debmirror  -v -p --no-check-gpg -h archive.ubuntu.com -r ubuntu -d xenial -s universe -a amd64 --method=http --nosource --exclude-field=Package='*' --include-field=Package='ceph-fs-common' --i18n --include="/Trans*" test
#./cobbler/bin/debmirror -v -p  --no-check-gpg -h archive.ubuntu.com --i18n -r ubuntu -d xenial -s universe -a amd64 --method=http --nosource ubuntu/repos/universe/ --='/*'  --include=ceph-fs-common --include=gir1.2-libosinfo --include=koan  --include=python-ethtool --include=python-koan --include=virt-manager --include=gtk-vnc --include=libgvnc --include=libgtk-vnc --include=spice-gtk --include=spice-client --include=libgtk-vnc --include=virt-viewer --include=libspice--include=virtinst --include=cobbler --include=libosinfo --include='/Translation-en*'
#./cobbler/bin/debmirror -v -p  --no-check-gpg -h archive.ubuntu.com --i18n -r ubuntu -d xenial -s universe -a amd64 --method=http --nosource ubuntu/repos/universe/ --exclude-field=Package='*' --include-field=Package=ceph-fs-common --include-field=Package=gir1.2-libosinfo --include-field=Package=koan --include-field=Package=python-ethtool --include-field=Package=python-koan --include-field=Package=virt-manager --include-field=Package=gtk-vnc --include-field=Package=libgvnc --include-field=Package=libgtk-vnc --include-field=Package=spice-gtk --include-field=Package=spice-client --include-field=Package=libgtk-vnc --include-field=Package=virt-viewer --include-field=Package=libspice --include-field=Package=virtinst --include-field=Package=cobbler --include-field=Package=libosinfo 
./cobbler/bin/debmirror -v -p  --no-check-gpg -h archive.ubuntu.com --i18n -r ubuntu -d xenial -s universe -a amd64 --method=http --nosource ubuntu/repos/universe/ --exclude-field=Package='*' --include-field=Package="ceph-fs-common|gir1.2-libosinfo|koan|python-ethtool|python-koan|virt-manager|gtk-vnc|libgvnc|libgtk-vnc|spice-gtk|spice-client|libgtk-vnc|virt-viewer|libspice|virtinst|cobbler|libosinfo|virt-viewer"



# Mirror Docker Repo
./cobbler/bin/debmirror -v -p --no-check-gpg --rsync-extra=none -h apt.dockerproject.org -r repo -d ubuntu-xenial -s main -a amd64 --method=http --nosource ubuntu/repos/docker

# Copy Ansible scripts
# 

# Create blank image. Should refactor this to happen right when everything's been downloaded for actual size estimate.
dd if=/dev/zero of=${OUTPUT_DIRECTORY}/${OUTPUT_IMAGE_NAME} bs=1M count=12000

# Creates loopback device for image.
# TODO: We should also get the resulting loopback device to pass into make-centos-bootstick.
kpartx -a ${OUTPUT_DIRECTORY}/${OUTPUT_IMAGE_NAME}

# Create usb image, this is a patched up thid party utility that needs to be refactored, and a PR sent back upstream.
./make-centos-bootstick -k ./ks.cfg -c ./syslinux.cfg -s ./k8splash.png loop0

# Clean up all loopback devices
dmsetup remove_all

