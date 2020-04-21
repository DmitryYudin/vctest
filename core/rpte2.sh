#
# Copyright © 2019 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#
set -eu -o pipefail

entrypoint()
{
if [ 1 == 1 ]; then
	jobsRunTasks "$@"
else
	cat tasks.txt | sed -e "s/'\r'$//" -e "s/[[:space:]]*$//" -e "s/^[[:space:]]*//" -e "s/[[:space:]]*:[[:space:]]*/:/" -e "s/[[:space:]]+/ /"| paste > tasks2.txt

	local tempPath="tmp/$(date "+%Y.%m.%d-%H.%M.%S")"
	mkdir -p $tempPath
	cd $tempPath >>/dev/null
	jobsRunTasks ../../tasks2.txt -j1 #-d':'
	cd - >/dev/null
	if ! jobsGetStatus; then
		echo "Complete with error"
	else
		echo "Success"
	fi
fi
}

# Progress reported to stdout (since report progress on interrupt)
# Errors are printed to stderr
readonly __jobsPipeDelim=$'\004' # EOT
readonly REPLY_EOF='-'
jobsGetStatus()
{	
	return $(( __jobsInterruptCnt + __jobsErrorCnt ))
}

jobsStartPing()
{
	local period=$1
	{
		trap 'return 0' INT
		while : ; do
			sleep $period
			echo "ping::0:"$__jobsPipeDelim > $__jobsStatusPipe
		done
	} </dev/null 1>/dev/null 2>/dev/null &
}
open_pipe_4()
{
	local pipeName=$1; shift
	while ! exec 4<$pipeName; do # prevent 'Device or resource busy' errror
		[ ! -e $pipeName ] && return 1
		sleep .1s
	done
	return 0
}
jobsStartWorker()
{
	local -
	set -eu

	local id=$1; shift
	local cmd=$1; shift
	local userText=$1; shift
	local userFlags=$1; shift

	local runningTaskId=
	local runningTaskCmd=
	onWorkerExit() {
		local error_code=0
		[ -n "$runningTaskId" ] && error_code=1
		echo "$BASHPID:$runningTaskId:$error_code:$runningTaskCmd"$__jobsPipeDelim > $__jobsStatusPipe
		exit $error_code
	}
	trap onWorkerExit EXIT

	# Continue reading while pipe exist
	while : ; do
		# Prepare command line
		eval 'set -- $cmd'
		for x; do shift; set -- "$@" "$(eval echo "$x")"; done

		# Prepare redirections
		exec 3>"$tempPath/$id.stdout.log"
		[ $__jobsStderrToStdout == 0 ] && exec 4>"$tempPath/$id.stderr.log"
		[ $__jobsStderrToStdout != 0 ] && exec 4>&3

		# Run
		runningTaskId=$id
		runningTaskCmd=$cmd${userFlags:+ "$userFlags"}
		{ # -errexit option set above!
			"$@"${userFlags:+ "$userFlags"}
			[ -n "$userText" ] && echo "$userText"
		} </dev/null 1>&3 2>&4 3>&- 4>&-
		exec 3>&- 4>&-
		# Aways report successfull status since exit trap expected to trig on failure
		echo "$BASHPID:$runningTaskId:0:$runningTaskCmd"$__jobsPipeDelim > $__jobsStatusPipe
		runningTaskId=
		runningTaskCmd=

		if ! open_pipe_4 $__jobsWorkPipe; then
			break
		fi
		{ readNewTask ':' <&4 && exec 4>&-; } || { exec 4>&- && break; }
	done
	trap -- EXIT
}
jobsReportProgress()
{
	local symCheck=$'\xe2\x88\x9a' symSun=$'\xe2\x98\xbc' symSmile=$'\xe2\x98\xba' symExcl=$'\xe2\x80\xbc' symTopDn=$'\xc2\xbf' symInf=$'\xe2\x88\x9e'
	local symUp=$'\xcb\x84' symDn=$'\xcb\x85' 
	local label=''
	local t=$((SECONDS - __jobsStartSec))

	local status=$symSun
	[ $__jobsNoMoreTasks != 0 ] && { [ $__jobsRunning != 0 ] && status=$symSmile || status=$symCheck; }
	[ $__jobsErrorCnt != 0 -o $__jobsInterruptCnt != 0 ] && status=$symExcl
	if [ $__jobsErrorCnt != 0 -o $__jobsInterruptCnt != 0 ]; then
		[ $__jobsTermReasonInt == 0 ] && label="#E=$__jobsErrorCnt" || label='INT'
	else
	#	local pos=$t
		local pos=$__jobsProgressCnt; __jobsProgressCnt=$(( __jobsProgressCnt + 1 ))
		local patt=\
">   ""->  ""--> ""--->""=-->"" =->""  =>""   >""   <"">  <""-> <""--><""=-><"" =><""  ><""  <<"\
"> <<""-><<""=><<"" ><<"" <<<""><<<""<<<<""-<<<""--<<""---<""----"" ---""  --""   -""    "
		label=${patt:$(( 4*(pos%31) )):4}		
	fi

	local tot="   "$symInf # 'printf' does not align unicode characters as expected
	[ $__jobsNoMoreTasks != 0 ] && tot=$(( __jobsDone + __jobsRunning )) # estimate
	[ $__jobsDoneMax != 0 ] && tot=$__jobsDoneMax # fine is known beforehand

	local runWidth=1
	[ $__jobsRunning -ge 10 ] && runWidth=2
	[ $__jobsRunning -ge 100 ] && runWidth=3
	{
		local timestamp
		local hr=$(( t/60/60 )) min=$(( (t/60) % 60 )) sec=$(( t % 60 ))
		[ ${#min} == 1 ] && min=0$min
		[ ${#sec} == 1 ] && sec=0$sec
		[ ${#hr}  == 1 ] && hr=0$hr
		timestamp="$hr:$min:$sec"
	}
	local str
	printf -v str "$timestamp %s[$symDn%4s/%4s][$symUp%${runWidth}s]%4s|%s" "$status" $__jobsDone "$tot" $__jobsRunning "$label" "$__jobsDisplay"
	if [ ${COLUMNS:-0} -gt 4 -a ${#str} -gt ${COLUMNS:-0} ]; then
		str=${str:0:$(( COLUMNS - 4 ))}...
	fi
	local CSI=$'\033[' RESET= CLR_R=
	[ -t 1 ] && { CLR_R=${CSI}0K; RESET=${CSI}m; }
	printf "${CLR_R}%s${RESET}\r" "$str"
}

jobsReportTaskFail()
{
	local id=$1; shift
	local status=$1; shift
	local cmd=$1; shift

	local CSI=$'\033[' RESET= CLR_R=
	[ -t 1 ] && { CLR_R=${CSI}0K; RESET=${CSI}m; }
	echo "${CLR_R}Fail:$id:$status:$cmd${RESET}"
	if [ $__jobsErrorCnt -eq 1 -o $__jobsLogLevel -gt 1 ]; then
		local color=yes BOLD= RED=
		[ -t 1 -a "$color" == yes ] && { BOLD=${CSI}1m; RED=${CSI}31m; }
		echo -e "$BOLD<stdout:$id>$(< "$tempPath/$id.stdout.log")$RESET"
		if [ "$__jobsStderrToStdout" == 0 ]; then
			echo -e "$BOLD$RED<stderr:$id>$(< "$tempPath/$id.stderr.log")$RESET"
		fi
	fi
}

readNewTask() 				# return 1 if End-Of-Stream detected
{             				# return 0 > set 'cmd'
	local delim=$1; shift   #          > set 'id' if 'delim' non empty, otherwise leave 'id' untouched
	local REPLY=
	# success if non-empty message received
	while read -r; do   # Remove leading and trailing whitespaces
		local x=$REPLY; x=${x#"${x%%[! $'\t']*}"}; x=${x%"${x##*[! $'\t']}"}; REPLY=$x
		case $REPLY in '#'*) continue;; esac # comment
		[ -z "$REPLY" ] && continue
		[ "$REPLY" == $REPLY_EOF ] && return 1

		cmd=$REPLY
		if [ -n "$delim" ]; then
			id=${REPLY%%$delim*}
			cmd=${REPLY#"$id$delim"}
			[ "$id" == "$REPLY" ] && echo "error: can't parse task id from '$REPLY'" && return 1
			x=$id;  x=${x%"${x##*[! $'\t']}"}; id=$x
			x=$cmd; x=${x#"${x%%[! $'\t']*}"}; cmd=$x
		fi
		# make sure $cmd is not empty
		[ -z "$cmd" ] && continue
		return 0
	done
	return 1
}

jobsRunTasks()
{
	local -
	set -eu

	local taskTxt= delim= tempPath=. logLevel= runMax=1 userText= userFlags=
	# set all 'kw' args to "-k v" form (accepted input: -kv | -k=v | -k v)
	while [ $# != 0 ]; do
		local i=$1 v; shift
		case $i in -*) v=${i:2}; i=${i:0:2}; v=${v#=}; 
			if [ -z "$v" ]; then
				[ $# == 0 ] && echo "error: argument required for '$i' option" >&2 && return 1
			 	v=$1; shift;
			fi 
		esac
		case $i in
			-d*) delim=$v;;
			-p*) tempPath=$v;;
			-l*) logLevel=$v;;
			-j*) runMax=$v;; # 0 => all CPUs, < 0 => nCPU+|x|
			-t*) userText=$v;;
			-f*) userFlags=$v;;
			*)	[ -z "$taskTxt" ] && { taskTxt=$i; continue; }
				echo "error: unrecognized option $i" >&2 && return 1;
		esac
	done
	[ -z "$taskTxt" ] && { echo "error: not task file" >&2 && return 1; }
	# Get last cpu index. We are going to use NCPU-1 cores to run
	if [ "$runMax" -le 0 ]; then
		x="$(grep 'processor' /proc/cpuinfo)"; x="${x##* }"; # last cpu index
		if [ "$runMax" == 0 ]; then
			runMax=$(( x + 1 ))
		else
			[ "$x" == 0 ] && runMax=1 || runMax=$((x + 1 - runMax))
		fi
	fi
	[ "$runMax" -le 0 ] && { echo "error: can't detect CPU number" >&2 && return 1; }

	mkdir -p "$tempPath"
	tempPath="$(cd "$tempPath" >/dev/null; pwd)"

	jobsOnINT() {
		# most likely stderr is redirected to /dev/null at this moment
		[ $__jobsInterruptCnt == 0 -a $__jobsErrorCnt == 0 ] && __jobsTermReasonInt=1
		__jobsInterruptCnt=$(( __jobsInterruptCnt + 1 ))
		# unblock everything
		rm -f -- $__jobsStatusPipe # need abspath to a 'pipe' since 'pwd' is unpredictable here
		rm -f -- $__jobsWorkPipe
		if [ -n "$__jobsPingPid" ]; then
			{ kill -s TERM $__jobsPingPid && wait $__jobsPingPid || true; } 2>/dev/null
			__jobsPingPid=
		fi
		if [ -n "$__jobsPid" ]; then
			{ kill -s KILL $__jobsPid && wait $__jobsPid || true; } 2>/dev/null
			__jobsPid=
		fi
		[ $__jobsInterruptCnt -ge 3 ] && exit 127

		return 0
	}
	jobsOnEXIT() {
		exec 4<&-
		rm -f -- $__jobsStatusPipe # need abspath to a 'pipe' since 'pwd' is unpredictable here
		rm -f -- $__jobsWorkPipe

		if [ -n "$__jobsPingPid" ]; then
			{ kill -s TERM $__jobsPingPid && wait $__jobsPingPid || true; } 1>/dev/null  2>/dev/null
		fi
		if [ -n "$__jobsPid" ]; then
			echo "warn: waiting for unfinished jobs: $__jobsPid"
			{ kill -s TERM $__jobsPid && wait $__jobsPid || true; } >/dev/null
		fi
		# due to previous 'rm' the worker may create file '$__jobsStatusPipe' on status report
		rm -f -- $__jobsStatusPipe

		{ jobsReportProgress; echo ""; }
	}
	__jobsStatusPipe="$tempPath/pipe_status"
	__jobsWorkPipe="$tempPath/pipe_work"
	__jobsRawIdx=0
	__jobsRunning=0
	__jobsLogLevel=1
	__jobsStderrToStdout=${1:-0}
	__jobsErrorCnt=0
	__jobsInterruptCnt=0
	__jobsTermReasonInt=0
	__jobsNoMoreTasks=0
	__jobsDone=0
	__jobsDoneMax=0
	__jobsStartSec=$SECONDS
	__jobsProgressCnt=0
	__jobsDisplay=
	__jobsPid=
	rm -f -- $__jobsStatusPipe

	local id= cmd=
	while readNewTask "$delim"; do
		__jobsDoneMax=$(( __jobsDoneMax + 1 ))
	done <"$taskTxt"

	mkfifo $__jobsStatusPipe
	mkfifo $__jobsWorkPipe

	jobsStartPing .3s
	__jobsPingPid=$!

	trap 'jobsOnINT' INT
	trap 'jobsOnEXIT' EXIT

	exec 4<"$taskTxt"

	while [ $__jobsRunning -lt $runMax ]; do
		local id= cmd=

		readNewTask "$delim" <&4 || break

		[ -n "$id" ] || { id=$__jobsRawIdx; __jobsRawIdx=$(( __jobsRawIdx + 1 )); }

		jobsStartWorker "$id" "$cmd" "$userText" "$userFlags" 4<&- &

		__jobsPid="$__jobsPid $!"
		__jobsDisplay=$id:$cmd${userFlags:+ $userFlags}
		__jobsRunning=$(( __jobsRunning + 1 ))
	done
	[ $__jobsRunning -lt $runMax ] && __jobsNoMoreTasks=1

	setWorkerGone() {
		local pid=$1 x=; shift
		{ wait $pid || true; } 2>/dev/null  # may have already gone
		set -- $__jobsPid; # remove from wait list
		for x; do shift; if [ $x != $pid ]; then set -- "$@" $x; fi; done
		__jobsPid="$@"
		__jobsRunning=$((__jobsRunning - 1))		# worker exit
	}
	while : ; do
		local pid id status data x
		# Untill have workers running
		while [ $__jobsRunning != 0 ]; do
			jobsReportProgress

			# Check feedback pipe still alived and not get destroyed on interrupt
			[ ! -e $__jobsStatusPipe ] && break

			# Only extract one message per pipe read access (i.e. not reading from 'fd' in a loop).
			# This case we will have 'read' blocked till message appeared in a pipe.
			# The return status is always expected to be zero with the exception for the interrupt.
			read -d $__jobsPipeDelim 2>/dev/null <$__jobsStatusPipe || continue

			# This is a 'ping' - skip it
			case $REPLY in ping:*) continue; esac

			# This is a status report - parse it
			x=$REPLY
			x=${REPLY%%:*}; REPLY=${REPLY#$x:}; pid=$x
			x=${REPLY%%:*}; REPLY=${REPLY#$x:}; id=$x  # maybe empty
			x=${REPLY%%:*}; REPLY=${REPLY#$x:}; status=$x
			data=$x
			if [ -z "$id" ]; then
				setWorkerGone $pid; pid= # worker exit due to interrupt
			else
				__jobsDone=$(( __jobsDone + 1 ))
				if [ "$status" != 0 ]; then
					setWorkerGone $pid; pid= # worker exit due to task fail

					__jobsErrorCnt=$(( __jobsErrorCnt + 1 ))
					jobsReportTaskFail "$id" $status "$data" >&2
				fi
			fi
			[ -n "$pid" ] && break; # worker is waiting us a new task
		done
		jobsReportProgress

		# Time to leave if no workers alive
		[ $__jobsRunning == 0 ] && break;

		# initialize 'id' ahead of readNewTask() call!
		local id= cmd=
		if [ $__jobsNoMoreTasks == 0 -a $__jobsErrorCnt == 0 -a $__jobsInterruptCnt == 0 ]; then
			readNewTask "$delim" <&4 || __jobsNoMoreTasks=1
		fi

		local task;
		# Reply with EOF message if no task was read
		if [ -z "$cmd" ]; then
			task=$REPLY_EOF
			__jobsDisplay=$task
		else
			pid= # leave worker alive
			[ -n "$id" ] || { id=$__jobsRawIdx; __jobsRawIdx=$(( __jobsRawIdx + 1 )); }
			task=$id:$cmd
			__jobsDisplay=$task${userFlags:+ $userFlags}
		fi
		jobsReportProgress
		echo "$task" 2>/dev/null >$__jobsWorkPipe

		if [ -n "$pid" ]; then
			setWorkerGone $pid; pid=; # worker exit
		fi
	done

	trap -- INT
	trap -- EXIT 

	# Do cleanup
	jobsOnEXIT || true

	jobsGetStatus
}

entrypoint "$@"
