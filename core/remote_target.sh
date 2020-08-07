#
# Copyright © 2020 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#

# Methods to work with remote target. (Android)
#   TARGET_setTarget      - set credentials
#   TARGET_getExecDir     - directory we can execute from
#   TARGET_getDataDir     - '/sdcard' for Android
#   TARGET_getFingerprint - device info
#   TARGET_pull
#   TARGET_push
#   TARGET_pushFileOnce - 'push' without overwrite
#
# Currently sticked to Android only. TODO:remote ssh host
#
TARGET_setTarget()
{
	local target=$1; shift
	local prms_script=${1=}

	ADB_SERIAL=;
	if [[ -n "$prms_script" ]]; then
		. "$prms_script"
		ADB_SERIAL=${serial:-}
	fi

	if [[ $target == adb ]]; then
		if command -p adb 1>/dev/null 2>&1; then
			HOST_ADB=adb
		else
			# Try default location if not found in $PATH
			if [[ -z "${ANDROID_HOME:-}" ]]; then
				case ${OS:-} in
					*_NT) ANDROID_HOME=$LOCALAPPDATA/Android/Sdk;;
					*) ANDROID_HOME=/Users/$(whoami)/Library/Android/sdk;;
				esac
			fi
			HOST_ADB=$ANDROID_HOME/platform-tools/adb
			[[ ! -x "${HOST_ADB:-}" ]] && echo "error: 'adb' not found" >&2 && return 1
		fi

		adb() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" command "$HOST_ADB" "$@"; }

		export ANDROID_SERIAL=$ADB_SERIAL  # used by adb
		export HOST_ADB
		export -f adb

		TARGET_getExecDir()     { _adb_getExecDir "$@"; }
		TARGET_getDataDir()     { _adb_getDataDir "$@"; }
		TARGET_getFingerprint() { _adb_getFingerprint "$@"; }
		TARGET_pull()           { _adb_pull "$@"; }
		TARGET_push()           { _adb_push "$@"; }
		TARGET_pushFileOnce()   { _adb_pushFileOnce "$@"; }
		TARGET_exec()           { _adb_exec "$@"; }
	else
		echo "error: unknown remote target '$target'" >&2
		return 1
	fi

	export -f \
		TARGET_getExecDir \
		TARGET_getDataDir \
		TARGET_pull \
		TARGET_push \
		TARGET_pushFileOnce \
		TARGET_exec
}
                   
#  _____ ____  _____ 
# |  _  |    \| __  |
# |     |  |  | __ -|
# |__|__|____/|_____|
#
_adb_getExecDir()
{
	REPLY=/data/local/tmp
}
_adb_getDataDir()
{
	REPLY="$(adb shell -n echo \$EXTERNAL_STORAGE)"
	REPLY=${REPLY%%$'\r'}
}
_adb_getFingerprint()
{
	REPLY=$( _adb_exec "
		board=\$(getprop ro.board.platform)       # kirin970
		cpuabi=\$(getprop ro.product.cpu.abi)     # arm64-v8a
		model=\$(getprop ro.product.model)        # CLT-AL00
		brand=\$(getprop ro.product.brand)        # HUAWEI
		name=\$(getprop ro.config.marketing_name) # HUAWEI P20 Pro
		echo \"\$board:\$cpuabi:\$brand:\$model:\$name\"
	")
}
_adb_pull()
{
	local remoteSrc=$1; shift
	local localDst=$1; shift

	adb pull "$remoteSrc" "$localDst"
}
_adb_push()
{
	local localSrc=$1; shift
	local remoteDst=$1; shift

	adb push "$localSrc" "$remoteDst"
}
_adb_pushFileOnce()
{
	local localSrc=$1; shift
	local remoteDst=$1; shift # maybe directory
	
	REPLY=$(_adb_exec "
		filepath=$remoteDst; [[ -d $remoteDst ]] && filepath=$remoteDst/$(basename $localSrc)
		[[ ! -e \$filepath ]] && rm -f \$filepath.stamp 2>/dev/null || true
		[[ ! -e \$filepath.stamp ]] && exit 0
		echo ok
	")
	[[ "$REPLY" == ok ]] && return

	_adb_push "$localSrc" "$remoteDst"
	_adb_exec "
		filepath=$remoteDst; [[ -d $remoteDst ]] && filepath=$remoteDst/$(basename $localSrc)
		date > \$filepath.stamp
	"
}
_adb_exec()
{
	adb shell -n "set -e; $@"
}
