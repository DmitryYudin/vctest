#
# Copyright © 2020 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#
set -eu

#
# There are different types of CPU cores may present on the same 
# device. The most widely used platform is an ARM big.LITTLE
# architecture. For the profiling purpose we need to have CPU
# state unchanged from the test start to the end.
# To achive that we only keep active a CPUs of same type and 
# disable all the others. And also, we disable CPU frequency
# control and set frequency to maximal value available.
#
usage()
{
	cat	<<-EOT
	Ineractive script to manage CPU cores for the Android device:
	    - Print info
	    - Enable/disable specific cores
	    - Set frequency and governor
	Note, any CPU setting modification requires root permission.
EOT
}

entrypoint()
{
	local push_self_to_target=false restarted=false

	while [ "$#" -gt 0 ]; do
		case $1 in
			-h|--help)		usage && return;;
			--restarted)	restarted=true;;
			*) echo "error: unrecognized option '$1'" >&2 && exit 1
		esac
		shift
	done
	# Expect MirBSD Korn Shell on Android device
	[[ -z ${KSH_VERSION:-} ]] && push_self_to_target=true

	if $push_self_to_target; then
		push_to_target
		return
	fi

	if $restarted; then
		echo "Sucessfully restarted as a root"
	elif ! check_root; then
		if command -v su >/dev/null 2>&1; then
			echo "Restarting self $0 with root permissions..."
			# Old 'su' requires '-' at the end
			if ! su - -c "$0 --restarted"; then
				su -c "$0 --restarted" -				
			fi
		fi
	else
		echo "Running with root permissions"
	fi

	REPLY=
	while [[ $REPLY != q ]]; do
		menu_main
	done

	if $restarted; then
		echo "This script may not exit automatically."
		echo "Press Ctrl^C to exit"
	fi
}

check_root()
{
	[[ $USER_ID == 0 ]]
	#[[ $(whoami) != root ]]
}
menu_main()
{
	echo "[ Main menu ]"
	echo "  1. Print CPU info"
	echo "  2. Print CPU group info"
	echo "  3. Enable CPU"
	echo "  4. Disable CPU"
	echo "  5. Disable CPU group"
	echo "  6. Set max frequency for the CPU group"

	echo "Choose what to do next, or press 'q' to quit:"
	while read -s; do
		local task=
		case $REPLY in
			q) return;;
			1) task=menu_cpus_info;;
			2) task=menu_group_info;;
			3) task=menu_cpu_enable;;
			4) task=menu_cpu_disable;;
			5) task=menu_group_disable;;
			6) task=menu_group_maxfreq;;
			*) continue;
		esac

		REPLY=c; 
		while :; do
			$task
			[[ $REPLY == c ]] && break;
		done
		break
	done
	REPLY=
}

menu_cpus_info()
{
	echo "[ CPU info ]"

	cpus_print

	REPLY=c
}

menu_group_info()
{
	echo "[ CPU group info ]"

	groups_update
	groups_print

	REPLY=c
}

menu_cpu_enable()
{
	echo "[ CPU enable ]"

	local cpu_list=
	build_cpu_list 0; cpu_list=$REPLY
	if [[ -z $cpu_list ]]; then
		echo "All possible CPUs are already in online state."
		echo "Press any key to return"
		read -s
		return
	fi

	echo "CPUs offline: $cpu_list"
	echo "Enter id to set CPU online or press 'c' to cancel:"
	while read -s; do
		[[ $REPLY == c ]] && return
		local known_cpu=false
		for cpu in $cpu_list; do
			[[ $REPLY == $cpu ]] && known_cpu=true && break
		done
		if $known_cpu; then
			set_cpu_state $cpu 1 || return 0
			break
		fi
	done
	echo Success
}

menu_cpu_disable()
{
	echo "[ CPU disable ]"

	local cpu_list=
	build_cpu_list 1; cpu_list=$REPLY

	echo "CPUs online: $cpu_list"
	echo "Enter id to set CPU offline or press 'c' to cancel:"
	while read -s; do
		[[ $REPLY == c ]] && return
		local known_cpu=false
		for cpu in $cpu_list; do
			[[ $REPLY == $cpu ]] && known_cpu=true && break
		done
		if $known_cpu; then
			set_cpu_state $cpu 0 || return 0
			break
		fi
	done
	echo Success
}

menu_group_disable()
{
	echo "[ Group disable ]"

	groups_update
	echo "groups available:"
	groups_print

	if [[ $GR_NUM == 1 ]]; then
		echo "Only one group of CPUs is available, can't disable."
		echo "Press any key to return"
		read -s
		return
	fi

	echo "Enter group index to disable [0-$((GR_NUM - 1))] or press 'c' to cancel:"
	while read -s; do
		[[ $REPLY == c ]] && return
		case $REPLY in [0-9]*) [[ 0 -le $REPLY && $REPLY -lt $GR_NUM ]] && break; esac
	done
	eval "gr_cpus=\$GR${REPLY}_cpus"
	echo "Disable CPUs $gr_cpus:"
	for cpu in $gr_cpus; do
		set_cpu_state $cpu 0 || return 0
	done
	echo Success

	REPLY=c
}

menu_group_maxfreq()
{
	echo "[ Set CPU group frequency ]"

	groups_update
	echo "groups available:"
	groups_print

	echo "Enter group index to modify [0-$((GR_NUM - 1))] or press 'c' to cancel:"
	while read -s; do
		[[ $REPLY == c ]] && return
		case $REPLY in [0-9]*) [[ 0 -le $REPLY && $REPLY -lt $GR_NUM ]] && break; esac
	done
	eval "gr_cpus=\$GR${REPLY}_cpus"
	eval "gr_fmax=\$GR${REPLY}_fmax"
	eval "gr_flst=\$GR${REPLY}_flst"

    get_list_size() {
        local list=$1 i= cnt=0; shift
        for i in $list; do cnt=$(( cnt + 1 )); done
        REPLY=$cnt
    }
    get_list_item_by_index() {
        local list=$1 idx=$2; i= cnt=0; shift 2
        for i in $list; do
            [[ $cnt == $idx ]] && break
            cnt=$(( cnt + 1 ))
        done
        REPLY=$i
    }
    local fr= i=0
    for fr in $gr_flst; do printf "%2d: %7s\n" $i $fr; i=$((i+1)); done
    local numFreq=
    get_list_size "$gr_flst"; numFreq=$REPLY
	echo "Enter frequency index [0-$((numFreq - 1))] or press 'c' to cancel:"
	while read -s; do
		[[ $REPLY == c ]] && return
		case $REPLY in [0-9]*) [[ 0 -le $REPLY && $REPLY -lt $numFreq ]] && break; esac
	done
    get_list_item_by_index "$gr_flst" $REPLY
    local freq=$REPLY

    local cpu=
	for cpu in $gr_cpus; do
		set_cpu_governor $cpu userspace || return 0
#		set_cpu_freq     $cpu $gr_fmax || return 0
		set_cpu_freq     $cpu $freq || return 0
	done
	echo Success

	REPLY=c
}

disable_cpu_control()
{
	check_root || { echo "error: root login required" >&2 && return 1; }

	# TODO: 'stop mpdecision' for the 
	if [[ -f /sys/devices/system/cpu/cpuhotplug/enabled ]]; then
		local hotplug=
		hotplug=$(cat /sys/devices/system/cpu/cpuhotplug/enabled)
		# It seems each write access resets cpu state
		if [[ $hotplug == 1 ]]; then
			echo 0 > /sys/devices/system/cpu/cpuhotplug/enabled
		fi
	fi
}
set_cpu_state()
{
	local cpu=$1; shift
	local req=$1; shift
	if [ ! -f /sys/devices/system/cpu/cpu$cpu/online ]; then
		echo "error: can't set cpu$cpu online/offline" >&2
		return 1
	fi
	local cur=$(cat /sys/devices/system/cpu/cpu$cpu/online)

	[[ $req == $cur ]] && return

	disable_cpu_control || return 1

	echo $req > /sys/devices/system/cpu/cpu$cpu/online
	cur=$(cat /sys/devices/system/cpu/cpu$cpu/online)
	if [[ $req != $cur ]]; then
		echo "error: failed set cpu$cpu state to '$req', current state is '$cur'" >&2
		return 1
	fi
}
set_cpu_governor()
{
	local cpu=$1; shift
	local req=$1; shift
	local cur=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor)

	[[ $req == $cur ]] && return

	disable_cpu_control || return 1

	echo $req > /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor
	cur=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor)
	if [[ $req != $cur ]]; then
		echo "error: failed set cpu$cpu governor to '$req', current governor is '$cur'" >&2
		return 1
	fi
}
set_cpu_freq()
{
	local cpu=$1; shift
	local req=$1; shift
	local cur=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_cur_freq)

	[[ $req == $cur ]] && return

	disable_cpu_control || return 1

	echo $req > /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_setspeed
	cur=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_cur_freq)
	if [[ $req != $cur ]]; then
		echo "error: failed set cpu$cpu frequency to '$req', current frequency is '$cur'" >&2
		return 1
	fi
}
build_cpu_list()
{
	local state=$1; shift
	local cpu= cpu_online=
	for cpu in $(cat /proc/cpuinfo | grep 'processor' | tr -s ' ' | cut -s -d ' ' -f2); do
		cpu_online="${cpu_online:+$cpu_online }$cpu"
	done
	# This is most likely a single core device
	[[ -z $cpu_online ]] && cpu_online=0

	REPLY=
	for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
		cpu=${cpu##*cpu}
		local is_online=0
		for cpu_ in $cpu_online; do
			[[ $cpu == $cpu_ ]] && is_online=1
		done
		[[ $state == $is_online ]] && REPLY="${REPLY:+$REPLY }$cpu"
	done
	return 0
}

#
# Expose:
#	GR{idx}_cpus="cpu0 cpu1 ..."
#	GR{idx}_fmin=fmin
#	GR{idx}_fmax=fmax
#	GR{idx}_govr=governor
#	GR_NUM
#
groups_update()
{
	local cpu= cpu_online=
	build_cpu_list 1; cpu_online="$REPLY"

	for cpu in $cpu_online; do
		local fmin= fmax= govr= flst=
		fmin=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_min_freq)
		fmax=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_max_freq)
        flst=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/stats/time_in_state | sort -n -u | cut -s -d' ' -f1 | tr $'\n' ' ')
        flst=${flst%% }
		govr=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor 2>/dev/null) || govr=N/A
		local CPU${cpu}_fmin=$fmin
		local CPU${cpu}_fmax=$fmax
		local CPU${cpu}_flst="$flst"
		local CPU${cpu}_govr="$govr"
	done
	local gr_cpus= gr_fmin= gr_fmax= gr_govr= idx=0
	for cpu in $cpu_online; do
		eval "fmin=\$CPU${cpu}_fmin"
		eval "fmax=\$CPU${cpu}_fmax"
		eval "flst=\$CPU${cpu}_flst"
		eval "govr=\$CPU${cpu}_govr"
		if [[ ${gr_fmin}-${gr_fmax} == ${fmin}-${fmax} ]]; then
			# update
			gr_cpus="$gr_cpus $cpu"
			gr_govr=$govr # assumes all CPUs in package share same governor value
		else
			if [[ -n $gr_fmin ]]; then
				# flush
				export GR${idx}_cpus="$gr_cpus"
				export GR${idx}_fmin=$gr_fmin
				export GR${idx}_fmax=$gr_fmax
				export GR${idx}_flst="$gr_flst"
				export GR${idx}_govr=$gr_govr
				idx=$(( idx + 1 ))
			fi
			# create
			gr_cpus=$cpu
			gr_fmin=$fmin
			gr_fmax=$fmax
			gr_flst=$flst
			gr_govr=$govr
		fi
	done
	export GR${idx}_cpus="$gr_cpus" # flush last
	export GR${idx}_fmin=$gr_fmin
	export GR${idx}_fmax=$gr_fmax
	export GR${idx}_flst="$gr_flst"
	export GR${idx}_govr=$gr_govr
	GR_NUM=$(( idx + 1 ))
}
groups_print()
{
	local gr_cpus= gr_fmin= gr_fmax= idx=0
	while [[ $idx < $GR_NUM ]]; do
		eval "gr_cpus=\$GR${idx}_cpus"
		eval "gr_fmin=\$GR${idx}_fmin"
		eval "gr_fmax=\$GR${idx}_fmax"
		eval "gr_flst=\$GR${idx}_flst"
		eval "gr_govr=\$GR${idx}_govr"
		printf "%2s [%7s %7s] %11s %s\n" $idx $gr_fmin $gr_fmax $gr_govr "$gr_cpus"
#		printf "   { %s }\n" "$gr_flst"
		idx=$(( idx + 1 ))
	done
}
cpus_print()
{
	local cpu_list=
	build_cpu_list 1; cpu_list=$REPLY

	local fcur= fmin= fmax= fgov=
	for cpu in $cpu_list; do
		fcur=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_cur_freq)
		fmin=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_min_freq)
		fmax=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/cpuinfo_max_freq)
		govr=$(cat /sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor 2>/dev/null) || govr=N/A
		printf "%2s [%7s %7s] %7s %s\n" $cpu $fmin $fmax $fcur $govr
	done

	build_cpu_list 0; cpu_list=$REPLY
	if [[ -n $cpu_list ]]; then
		echo "offline: $cpu_list"
	fi
}

push_to_target()
{	# copy self to device than run
	adb() {
		if ! type -f adb >/dev/null 2>&1; then
			echo "error: 'adb' not found" && return 1
		fi
		MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL="*" command adb "$@";
	}
	adb push "$0" /data/local/tmp
	adb shell -n "chmod 777 /data/local/tmp/$(basename $0)"
	# run in interactive mode
	adb shell    "/data/local/tmp/$(basename $0)"
}

entrypoint "$@"
