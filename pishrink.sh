#!/usr/bin/env bash

# Project: PiShrink
# Description: PiShrink is a bash script that automatically shrink a pi image that will then resize to the max size of the SD card on boot.
# Link: https://github.com/Drewsif/PiShrink

version="v24.10.23"

CURRENT_DIR="$(pwd)"
SCRIPTNAME="${0##*/}"
MYNAME="${SCRIPTNAME%.*}"
LOGFILE="${CURRENT_DIR}/${SCRIPTNAME%.*}.log"
REQUIRED_TOOLS="parted losetup tune2fs md5sum e2fsck resize2fs"
ZIPTOOLS=("gzip xz")
declare -A ZIP_PARALLEL_TOOL=( [gzip]="pigz" [xz]="xz" ) # parallel zip tool to use in parallel mode
declare -A ZIP_PARALLEL_OPTIONS=( [gzip]="-f9" [xz]="-T0" ) # options for zip tools in parallel mode
declare -A ZIPEXTENSIONS=( [gzip]="gz" [xz]="xz" ) # extensions of zipped files

function info() {
	echo "$SCRIPTNAME: $1"
}

function error() {
	echo -n "$SCRIPTNAME: ERROR occurred in line $1: "
	shift
	echo "$@"
}

function cleanup() {
	if losetup "$loopback" &>/dev/null; then
		losetup -d "$loopback"
	fi
	if [ "$debug" = true ]; then
		local old_owner=$(stat -c %u:%g "$src")
		chown "$old_owner" "$LOGFILE"
	fi

}

function logVariables() {
	if [ "$debug" = true ]; then
		echo "Line $1" >> "$LOGFILE"
		shift
		local v var
		for var in "$@"; do
			eval "v=\$$var"
			echo "$var: $v" >> "$LOGFILE"
		done
	fi
}

function checkFilesystem() {
	info "Checking filesystem"
	e2fsck -pf "$loopback"
	(( $? < 4 )) && return

	info "Filesystem error detected!"

	info "Trying to recover corrupted filesystem"
	e2fsck -y "$loopback"
	(( $? < 4 )) && return

if [[ $repair == true ]]; then
	info "Trying to recover corrupted filesystem - Phase 2"
	e2fsck -fy -b 32768 "$loopback"
	(( $? < 4 )) && return
fi
	error $LINENO "Filesystem recoveries failed. Giving up..."
	exit 9

}

function set_autoexpand() {
    #Make pi expand rootfs on next boot
    mountdir=$(mktemp -d)
    partprobe "$loopback"
    sleep 3
    umount "$loopback" > /dev/null 2>&1
    mount "$loopback" "$mountdir" -o rw
    if (( $? != 0 )); then
      info "Unable to mount loopback, autoexpand will not be enabled"
      return
    fi

    if [ ! -d "$mountdir/etc" ]; then
        info "/etc not found, autoexpand will not be enabled"
        umount "$mountdir"
        return
    fi

    if [[ ! -f "$mountdir/etc/rc.local" ]]; then
        info "An existing /etc/rc.local was not found, autoexpand may fail..."
    fi

    if ! grep -q "## PiShrink https://github.com/Drewsif/PiShrink ##" "$mountdir/etc/rc.local"; then
      echo "Creating new /etc/rc.local"
    if [ -f "$mountdir/etc/rc.local" ]; then
        mv "$mountdir/etc/rc.local" "$mountdir/etc/rc.local.bak"
    fi

cat <<'EOFRC' > "$mountdir/etc/rc.local"
#!/bin/bash
# Copyright (c) 2019, NVIDIA CORPORATION. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

# This is a script to resize partition and filesystem on the root partition
# This will consume all un-allocated sapce on SD card after boot.

set -e

# 檢查是否在 Jetson Nano 上運行
if [ -e "/proc/device-tree/compatible" ]; then
	model="$(tr -d '\0' < /proc/device-tree/compatible)"
	if [[ "${model}" =~ "jetson-nano" ]]; then
		model="jetson-nano"
	fi
fi

if [ "${model}" != "jetson-nano" ]; then
	echo "Not a Jetson Nano, skipping resize."
	# 恢復 rc.local 並退出
	if [ -f /etc/rc.local.bak ]; then mv /etc/rc.local.bak /etc/rc.local; fi
	exit 0
fi

echo "Starting NVIDIA partition resize process..."

# 步驟 1: 將備份 GPT 頭移動到磁碟末尾
echo "Moving backup GPT header to the end of the disk..."
sgdisk --move-second-header /dev/mmcblk0

# 步驟 2: 備份根分區 (APP, No. 1) 的重要元數據
echo "Backing up partition metadata..."
partition_name="$(sgdisk -i 1 /dev/mmcblk0 | grep "Partition name" | cut -d\' -f2)"
partition_type="$(sgdisk -i 1 /dev/mmcblk0 | grep "Partition GUID code:" | cut -d' ' -f4)"
partition_uuid="$(sgdisk -i 1 /dev/mmcblk0 | grep "Partition unique GUID:" | cut -d' ' -f4)"
start_sector="$(cat /sys/block/mmcblk0/mmcblk0p1/start)"

# 步驟 3: 刪除並以最大尺寸重建根分區，同時恢復所有元數據
echo "Re-creating partition 1 to fill available space..."
sgdisk -d 1 -n 1:"${start_sector}":0 -c 1:"${partition_name}" \
	-t 1:"${partition_type}" -u 1:"${partition_uuid}" /dev/mmcblk0

# 步驟 4: 通知核心分區表已變更
echo "Informing kernel about partition changes..."
partprobe /dev/mmcblk0

# 步驟 5: 擴展 ext4 檔案系統
echo "Resizing filesystem..."
resize2fs /dev/mmcblk0p1

echo "Partition and filesystem resize successful!"

# --- 自我銷毀機制 ---
echo "Cleaning up rc.local to prevent re-execution..."
if [ -f /etc/rc.local.bak ]; then
    mv /etc/rc.local.bak /etc/rc.local
else
    echo "#!/bin/sh -e" > /etc/rc.local
    echo "exit 0" >> /etc/rc.local
    chmod +x /etc/rc.local
fi

# echo "擴展完成，系統將重新啟動..."
sleep 1
reboot

exit 0
EOFRC

    chmod +x "$mountdir/etc/rc.local"
    fi
    umount "$mountdir"
}

help() {
	local help
	read -r -d '' help << EOM
Usage: $0 [-adhnrsvzZ] imagefile.img [newimagefile.img]

  -s         Don't expand filesystem when image is booted the first time
  -v         Be verbose
  -n         Disable automatic update checking
  -r         Use advanced filesystem repair option if the normal one fails
  -z         Compress image after shrinking with gzip
  -Z         Compress image after shrinking with xz
  -a         Compress image in parallel using multiple cores
  -d         Write debug messages in a debug log file
EOM
	echo "$help"
	exit 1
}

should_skip_autoexpand=false
debug=false
update_check=true
repair=false
parallel=false
verbose=false
ziptool=""

while getopts ":adnhrsvzZ" opt; do
  case "${opt}" in
    a) parallel=true;;
    d) debug=true;;
    n) update_check=false;;
    h) help;;
    r) repair=true;;
    s) should_skip_autoexpand=true ;;
    v) verbose=true;;
    z) ziptool="gzip";;
    Z) ziptool="xz";;
    *) help;;
  esac
done
shift $((OPTIND-1))

if [ "$debug" = true ]; then
	info "Creating log file $LOGFILE"
	rm "$LOGFILE" &>/dev/null
	exec 1> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&1)
	exec 2> >(stdbuf -i0 -o0 -e0 tee -a "$LOGFILE" >&2)
fi

echo -e "PiShrink $version - https://github.com/Drewsif/PiShrink\n"

# Try and check for updates
if $update_check; then
  latest_release=$(curl -m 5 https://api.github.com/repos/Drewsif/PiShrink/releases/latest 2>/dev/null | grep -i "tag_name" 2>/dev/null | awk -F '"' '{print $4}' 2>/dev/null)
  if [[ $? ]] && [ "$latest_release" \> "$version" ]; then
    echo "WARNING: You do not appear to be running the latest version of PiShrink. Head on over to https://github.com/Drewsif/PiShrink to grab $latest_release"
    echo ""
  fi
fi

#Args
src="$1"
img="$1"

#Usage checks
if [[ -z "$img" ]]; then
  help
fi

if [[ ! -f "$img" ]]; then
  error $LINENO "$img is not a file..."
  exit 2
fi
if (( EUID != 0 )); then
  error $LINENO "You need to be running as root."
  exit 3
fi

# set locale to POSIX(English) temporarily
# these locale settings only affect the script and its sub processes

export LANGUAGE=POSIX
export LC_ALL=POSIX
export LANG=POSIX

# check selected compression tool is supported and installed
if [[ -n $ziptool ]]; then
	if [[ ! " ${ZIPTOOLS[@]} " =~ $ziptool ]]; then
		error $LINENO "$ziptool is an unsupported ziptool."
		exit 17
	else
		if [[ $parallel == true && $ziptool == "gzip" ]]; then
			REQUIRED_TOOLS="$REQUIRED_TOOLS pigz"
		else
			REQUIRED_TOOLS="$REQUIRED_TOOLS $ziptool"
		fi
	fi
fi

#Check that what we need is installed
for command in $REQUIRED_TOOLS; do
  command -v $command >/dev/null 2>&1
  if (( $? != 0 )); then
    error $LINENO "$command is not installed."
    exit 4
  fi
done

#Copy to new file if requested
if [ -n "$2" ]; then
  f="$2"
  if [[ -n $ziptool && "${f##*.}" == "${ZIPEXTENSIONS[$ziptool]}" ]]; then	# remove zip extension if zip requested because zip tool will complain about extension
    f="${f%.*}"
  fi
  info "Copying $1 to $f..."
  cp --reflink=auto --sparse=always "$1" "$f"
  if (( $? != 0 )); then
    error $LINENO "Could not copy file..."
    exit 5
  fi
  old_owner=$(stat -c %u:%g "$1")
  chown "$old_owner" "$f"
  img="$f"
fi

# cleanup at script exit
trap cleanup EXIT

#Gather info
info "Gathering data"
beforesize="$(ls -lh "$img" | cut -d ' ' -f 5)"
parted_output="$(parted -ms "$img" unit B print)"
rc=$?
if (( $rc )); then
	error $LINENO "parted failed with rc $rc"
	info "Possibly invalid image. Run 'parted $img unit B print' manually to investigate"
	exit 6
fi
partnum="$(echo "$parted_output" | tail -n 1 | cut -d ':' -f 1)"
partstart="$(echo "$parted_output" | tail -n 1 | cut -d ':' -f 2 | tr -d 'B')"
if [ -z "$(parted -s "$img" unit B print | grep "$partstart" | grep logical)" ]; then
    parttype="primary"
else
    parttype="logical"
fi
loopback="$(losetup -f --show -o "$partstart" "$img")"
tune2fs_output="$(tune2fs -l "$loopback")"
rc=$?
if (( $rc )); then
    echo "$tune2fs_output"
    error $LINENO "tune2fs failed. Unable to shrink this type of image"
    exit 7
fi

currentsize="$(echo "$tune2fs_output" | grep '^Block count:' | tr -d ' ' | cut -d ':' -f 2)"
blocksize="$(echo "$tune2fs_output" | grep '^Block size:' | tr -d ' ' | cut -d ':' -f 2)"

logVariables $LINENO beforesize parted_output partnum partstart parttype tune2fs_output currentsize blocksize

#Check if we should make pi expand rootfs on next boot
if [ "$parttype" == "logical" ]; then
  echo "WARNING: PiShrink does not yet support autoexpanding of this type of image"
elif [ "$should_skip_autoexpand" = false ]; then
  set_autoexpand
else
  echo "Skipping autoexpanding process..."
fi

#Make sure filesystem is ok
checkFilesystem

if ! minsize=$(resize2fs -P "$loopback"); then
	rc=$?
	error $LINENO "resize2fs failed with rc $rc"
	exit 10
fi
minsize=$(cut -d ':' -f 2 <<< "$minsize" | tr -d ' ')
logVariables $LINENO currentsize minsize
if [[ $currentsize -eq $minsize ]]; then
  info "Filesystem already shrunk to smallest size. Skipping filesystem shrinking"
else
  #Add some free space to the end of the filesystem
  extra_space=$(($currentsize - $minsize))
  logVariables $LINENO extra_space
  for space in 5000 1000 100; do
    if [[ $extra_space -gt $space ]]; then
      minsize=$(($minsize + $space))
      break
    fi
  done
  logVariables $LINENO minsize

  #Shrink filesystem
  info "Shrinking filesystem"
  if [ -z "$mountdir" ]; then
    mountdir=$(mktemp -d)
  fi

  resize2fs -p "$loopback" $minsize
  rc=$?
  if (( $rc )); then
    error $LINENO "resize2fs failed with rc $rc"
    mount "$loopback" "$mountdir"
    mv "$mountdir/etc/rc.local.bak" "$mountdir/etc/rc.local"
    umount "$mountdir"
    losetup -d "$loopback"
    exit 12
  else
    info "Zeroing any free space left"
    mount "$loopback" "$mountdir"
    cat /dev/zero > "$mountdir/PiShrink_zero_file" 2>/dev/null
    info "Zeroed $(ls -lh "$mountdir/PiShrink_zero_file" | cut -d ' ' -f 5)"
    rm -f "$mountdir/PiShrink_zero_file"
    umount "$mountdir"
  fi
  sleep 1

  #Shrink partition
  info "Shrinking partition"
  partnewsize=$(($minsize * $blocksize))
  newpartend=$(($partstart + $partnewsize))
  logVariables $LINENO partnewsize newpartend
  parted -s -a minimal "$img" rm "$partnum"
  rc=$?
  if (( $rc )); then
    error $LINENO "parted failed with rc $rc"
    exit 13
  fi

  parted -s "$img" unit B mkpart "$parttype" "$partstart" "$newpartend"
  rc=$?
  if (( $rc )); then
    error $LINENO "parted failed with rc $rc"
    exit 14
  fi

  #Truncate the file
  info "Truncating image"
  endresult=$(parted -ms "$img" unit B print free)
  rc=$?
  if (( $rc )); then
    error $LINENO "parted failed with rc $rc"
    exit 15
  fi

  endresult=$(tail -1 <<< "$endresult" | cut -d ':' -f 2 | tr -d 'B')
  logVariables $LINENO endresult
  truncate -s "$endresult" "$img"
  rc=$?
  if (( $rc )); then
    error $LINENO "truncate failed with rc $rc"
    exit 16
  fi
fi

# handle compression
if [[ -n $ziptool ]]; then
	options=""
	envVarname="${MYNAME^^}_${ziptool^^}" # PISHRINK_GZIP or PISHRINK_XZ environment variables allow to override all options for gzip or xz
	[[ $parallel == true ]] && options="${ZIP_PARALLEL_OPTIONS[$ziptool]}"
	[[ -v $envVarname ]] && options="${!envVarname}" # if environment variable defined use these options
	[[ $verbose == true ]] && options="$options -v" # add verbose flag if requested

	if [[ $parallel == true ]]; then
		parallel_tool="${ZIP_PARALLEL_TOOL[$ziptool]}"
		info "Using $parallel_tool on the shrunk image"
		if ! $parallel_tool ${options} "$img"; then
			rc=$?
			error $LINENO "$parallel_tool failed with rc $rc"
			exit 18
		fi

	else # sequential
		info "Using $ziptool on the shrunk image"
		if ! $ziptool ${options} "$img"; then
			rc=$?
			error $LINENO "$ziptool failed with rc $rc"
			exit 19
		fi
	fi
	img=$img.${ZIPEXTENSIONS[$ziptool]}
fi

aftersize=$(ls -lh "$img" | cut -d ' ' -f 5)
logVariables $LINENO aftersize

info "Shrunk $img from $beforesize to $aftersize"
