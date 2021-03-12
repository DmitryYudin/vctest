#
# Copyright © 2019 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#
set -eu -o pipefail

ENABLE_NAMED_PIPE=${ENABLE_NAMED_PIPE:-1}

usage()
{
	cat<<-\EOT
	Parallel task executor in Bash.

	This script reads a text file (testplan), where each line is a simple shell 
	command. For each line, the substitution of shell variables is performed,
	followed by the execution of the resulting expression. No more commands are
	scheduled if execution failed. Instead, the stdout/stderr logs are printed
	on the screen, all scheduled commands are waited to complete and script
	terminates with nonzero status.

	Normally, only execution progress is displayed. Each task is executed with
	the output streams redirected to a '$tempPath/$id.std{out,err}.log' files
	where 'id' is an auto incremented number or an  unique tag specified as a
	command prefix.

	This script requires bash to use 'errexit' mode. Do not call it as a part
	of composed shell command, see 'set -e' description at
	https://www.gnu.org/software/bash/manual/html_node/The-Set-Builtin.html

	Usage:
	    rpte.sh <testplan> [options]

	Options:
	    -h|--help    Print this help
	       --test    Run test
	    -p <path>    Temporary path for stdout/stderr logs
	    -j <n>       Maximum number of tasks running in parallel (default: 1)
	                    =  0 - all CPUs
	                    = -1 - all CPUs - 1    (i.e. reserve one core)
	                    <  0 - all CPUs + |n|
	    -d <char>    Task id delimiter: ':', ' ', ... . If not set, the Id is
	                 generated automatically in the execution order (default: auto)
	    -t <text>    Text message to append to stdout log for every executed task
	    -f <flags>   Flags to append to a command line for every task
EOT
# 'R' for 'reliable'
}

entrypoint()
{
	local BUSYBOX=$(cat --help 2>&1 | head -1 | grep BusyBox) || true
	[[ -n "$BUSYBOX" ]]             && ENABLE_NAMED_PIPE=0 # not supported
	[[ -n "${KSH_VERSION:-}" ]]     && ENABLE_NAMED_PIPE=0 # not supported (Android shell)
	[[ -n "${WSL_DISTRO_NAME:-}" ]] && ENABLE_NAMED_PIPE=0 # broken
	readonly ENABLE_NAMED_PIPE
    [[ $ENABLE_NAMED_PIPE == 0 ]] && echo "warning: multithreading execution disabled"

	local do_test=false
	for arg do
		shift
		case $arg in
			-h|--help) usage; return;;
			   --test) do_test=true;;
			*) set -- "$@" "$arg";;
		esac
	done

	if ! $do_test; then
		jobsRunTasks "$@"
		jobsGetStatus || return 1
	else
        local i=0 N=20
        rm -f tasks.txt
		rm -rf tmp
        echo "Scheduling $((N*10)) tasks..."
        printf -v REPLY '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n' true true true true true true true true true true;
        while [[ $i -lt $N ]]; do
            i=$((i+1))
            echo "$REPLY"
        done >> tasks.txt
		jobsRunTasks tasks.txt -j20 -p tmp
		jobsGetStatus || { echo "Complete with error" && return 1; }
		echo "Success"
	fi
}

# Progress reported to stdout (since report progress on interrupt)
# Errors are printed to stderr
readonly ARG_DELIM=$'\004' # EOT (non-printable)
readonly REPLY_EOF='-'
jobsGetStatus()
{	
	return $(( __jobsInterruptCnt + __jobsErrorCnt ))
}

# Ping self to report execution progress till the statusPIPE opened
jobsStartPing()
{
	[[ $ENABLE_NAMED_PIPE != 1 ]] && return 1

	local period=$1
	{
		trap 'return 0' INT

        exec 40>${__jobsStatusPipe}.lock
        while [[ -e $__jobsStatusPipe ]]; do
            flock 40
            echo "ping::0:" > $__jobsStatusPipe
            flock -u 40
			sleep $period
        done
	} </dev/null 1>/dev/null 2>/dev/null &
}

MASTER=0
WORKER=1
#mq_create
#
# Execute single task with output streams redirected to $tempPath/$id.stream.log
# Set exist status to task execution status.
#
# For the '$cmd' argument the variables substitution is executed first. Thus,
# any string starting with a '$' sign is expanded in the current Bash context:
#     cmd="test -i $dirVec/name -o $dirOut/name.out"
# The result of the expansion must be a simple command, i.e. not a command list
# separated with ';' or piped commands or composed commands ('&&', '||'). Due
# to expansion stage all braces must be escaped:
#     cmd="test -i \"name with whitespaces/name\" -o $dirOut/name.out"
#
executeSingleTask()
{
	local id=$1; shift	
	local cmd=$1; shift
	local userText=$1; shift
	local userFlags=$1; shift
	local x=

	# Append flags to command-line
	cmd=$cmd${userFlags:+ "$userFlags"}

	# Prepare command line
	eval 'set -- $cmd'
	for x; do shift;
		x=$(eval printf "%s" "$x") # can't use 'echo' here due to '-e'
		set -- "$@" "$x"
	done

	# Hack. Update cmd with evaluated parameters (just for debugging)
	runningTaskCmd="$@"

	# Prepare redirections
	exec 3>"$tempPath/$id.stdout.log"
	[[ $__jobsStderrToStdout == 0 ]] && exec 4>"$tempPath/$id.stderr.log"
	[[ $__jobsStderrToStdout != 0 ]] && exec 4>&3

	# Run
	local error_code=0
	{
		"$@"
        error_code=$?
		[[ -n "$userText" ]] && echo "$userText"
	} </dev/null 1>&3 2>&4 3>&- 4>&-
	exec 3>&- 4>&-

	return $error_code
}

#
# Worker
#
# Run worker process with the first task specified in the arguments list. Upon
# completion, the execution status is written into statusPIPE. If task succeded,
# next task is read from the workPipe and executed (and so on), otherwise worker
# thread exits.
# Note, we intentionly does not check execution status explicitly. Instead, we
# relies on Bash errexit mode which trigs exception on a Bash command failure.
# We catch this exception with the EXIT signal trap. The reason for this 
# behaviour is that master process expects us a response for every tasks read
# from a workPIPE (and exactly ONE response). When receiving any signal (ex.
# Ctrl^C press) we check whether the task is currently running, and if running
# we report fail execution status before leaving the process(self). In total,
# for each request (task read) we report completion status once and report
# additional 'process exit' status if we were interrupted. We report nothing 
# on normal process exit. We still may catch a race condition if interrupt
# appears in between writing to the statusPIPE and clearing the 'runningTaskId'
# variable.
debug_log_init()
{
    local type=$1 logfile=
    [[ $type == worker ]] && logfile=worker.$BASHPID.log || logfile=master.log
	rm -f "$tempPath/$logfile"
}
debug_log()
{
    local type=$1 logfile=
    [[ $type == worker ]] && logfile=worker.$BASHPID.log || logfile=master.log
    echo "$@" >> $tempPath/$logfile
}
jobsStartWorker()
{
	[[ $ENABLE_NAMED_PIPE != 1 ]] && return 1

#	local -
	set -eu

	local id=$1; shift
	local cmd=$1; shift
	local userText=$1; shift
	local userFlags=$1; shift

	local runningTaskId=
	local runningTaskCmd=
local OpeningPipeR=0
    local workDone=

exec 30>${__jobsWorkPipe}.lock
exec 40>${__jobsStatusPipe}.lock

	onWorkerExit() {
		local error_code=0
		[[ -n "$runningTaskId" ]] && error_code=1
		[[ -n "$workDone" ]] && error_code=0

        debug_log worker "exit: id=$runningTaskId workDone=$workDone error_code=$error_code"
        debug_log worker "OpeningPipeR=$OpeningPipeR"

		# open pipe first to avoid 'echo: write error: Broken pipe' message
        debug_log worker "onexit[submit]: $error_code"
        flock 40
        echo "$BASHPID:$runningTaskId:$error_code:$runningTaskCmd" > $__jobsStatusPipe
        flock -u 40
        debug_log worker "onexit[------]: $error_code"

        debug_log worker "Done"
		exit $error_code
	}
	trap onWorkerExit EXIT

	# Continue reading while pipe exist
	while : ; do
		runningTaskId=$id
		runningTaskCmd=$cmd${userFlags:+ "$userFlags"}

        debug_log worker "Exec: id=$id cmd=[$cmd]"
       	executeSingleTask "$id" "$cmd" "$userText" "$userFlags"

		# Report successful status since exit trap is expected to trig on failure
		# open pipe first to avoid 'echo: write error: Broken pipe' message
        debug_log worker "status[submit]: id=$id"
        flock 40
   		echo "$BASHPID:$runningTaskId:0:$runningTaskCmd" > $__jobsStatusPipe
flock -u 40
        debug_log worker "status[------]: id=$id"

		runningTaskId=
		runningTaskCmd=

REPLY=
        flock 30
		while [[ -z "$REPLY" ]]; do
    		readNewTask ':' <$__jobsWorkPipe || true
		done
		flock -u 30
		if [[ "$REPLY" == "$REPLY_EOF" ]]; then
            debug_log worker "no more tasks"
			break
		fi
		id=${REPLY%$ARG_DELIM*}
		cmd=${REPLY#*$ARG_DELIM}
		debug_log worker "workPipe id=$REPLY"

	done
    debug_log worker "exit main loop"

    workDone=1
    exit 0
}

# unicode characters
readonly symTopDn=$'\xc2\xbf' symUp=$'\xcb\x84' symDn=$'\xcb\x85' symInf=$'\xe2\x88\x9e'
readonly symCheck=$'\xe2\x88\x9a' symSun=$'\xe2\x98\xbc' symSmile=$'\xe2\x98\xba' symExcl=$'\xe2\x80\xbc'
pbar_getStatus()
{
	REPLY=$symSun
	[[ $__jobsNoMoreTasks != 0 ]] && { [[ $__jobsRunning != 0 ]] && REPLY=$symSmile || REPLY=$symCheck; }
	[[ $__jobsErrorCnt != 0 || $__jobsInterruptCnt != 0 ]] && REPLY=$symExcl
	return 0
}
pbar_getAnim()
{
#	local pos=$1; shift
	[[ -z "${__aminCounter:-}" ]] && __aminCounter=0 # static variable here
	local pos=$__aminCounter; __aminCounter=$(( __aminCounter + 1 ))
	local patt=\
">   ""->  ""--> ""--->""=-->"" =->""  =>""   >""   <"">  <""-> <""--><""=-><"" =><""  ><""  <<"\
"> <<""-><<""=><<"" ><<"" <<<""><<<""<<<<""-<<<""--<<""---<""----"" ---""  --""   -""    "
	REPLY=${patt:$(( 4*(pos%31) )):4}
}
pbar_getTimestamp()
{
	local dt=$1; shift
	local hr=$(( dt/60/60 )) min=$(( (dt/60) % 60 )) sec=$(( dt % 60 ))
	[[ ${#min} == 1 ]] && min=0$min
	[[ ${#sec} == 1 ]] && sec=0$sec
	[[ ${#hr}  == 1 ]] && hr=0$hr
	REPLY="$hr:$min:$sec"
}
pbar_getJobsMax()
{
	REPLY="   "$symInf # 'printf' does not align unicode characters as expected
	[[ $__jobsNoMoreTasks != 0 ]] && REPLY=$(( __jobsDone + __jobsRunning )) # estimate
	[[ $__jobsDoneMax != 0 ]] && REPLY=$__jobsDoneMax # use if known beforehand
	return 0;
}
jobsReportProgress()
{
	local dt=$((SECONDS - __jobsStartSec))
	local status= label= timestamp=

	pbar_getStatus;        status=$REPLY
	pbar_getTimestamp $dt; timestamp=$REPLY
	pbar_getAnim      $dt; label=$REPLY
	pbar_getJobsMax;       tot=$REPLY

	# replace animation by error info
	if [[ $__jobsErrorCnt != 0 || $__jobsInterruptCnt != 0 ]]; then
		[[ $__jobsTermReasonInt == 0 ]] && label="#E=$__jobsErrorCnt" || label='INT'
	fi

	local runWidth=1
	[[ $__jobsRunning -ge 10 ]] && runWidth=2
	[[ $__jobsRunning -ge 100 ]] && runWidth=3

	local str
	if [[ $ENABLE_NAMED_PIPE == 1 ]]; then
		printf -v str "$timestamp %s[%4s/%4s][#%${runWidth}s]%4s|%s" \
			"$status" $__jobsDone "$tot" $__jobsRunning "$label" "$__jobsDisplay"
	else
		printf -v str "$timestamp %s[%4s/%4s]%s" \
			"$status" $__jobsDone "$tot" "$__jobsDisplay"
	fi

	if [[ ${COLUMNS:-0} -gt 4 && ${#str} -gt ${COLUMNS:-0} ]]; then
		str=${str:0:$(( COLUMNS - 5 ))}...
	fi
	local CSI=$'\033[' RESET= CLR_R=
	[[ -t 1 ]] && { CLR_R=${CSI}0K; RESET=${CSI}m; }
	printf "${CLR_R}%s${RESET}\r" "$str"
}

jobsReportTaskFail()
{
	local id=$1; shift
	local status=$1; shift
	local cmd=$1; shift

	local CSI=$'\033[' RESET= CLR_R=
	[[ -t 1 ]] && { CLR_R=${CSI}0K; RESET=${CSI}m; }
	echo "" # push progressbar
	echo "${CLR_R}Fail:$id:$status:$cmd${RESET}"
	if [[ $__jobsErrorCnt -eq 1 || $__jobsLogLevel -gt 1 ]]; then
		local color=yes BOLD= RED=
		[[ -t 1 && "$color" == yes ]] && { BOLD=${CSI}1m; RED=${CSI}31m; }
		echo -e "$BOLD<stdout:$id>"
		cat "$tempPath/$id.stdout.log"
		if [[ "$__jobsStderrToStdout" == 0 ]]; then
			echo -e "$BOLD$RED<stderr:$id>"
			cat "$tempPath/$id.stderr.log"
		fi
		echo -e "$RESET"
	fi
}

# Read ID and CMD for the next task from stdin.
# (ID is only read if delimiter argument set)
#
# Return value is a REPLY variable in a form of "$id$ARG_DELIM$cmd"
# Emty return value signals the end of the task list.
readNewTask() 				
{
	local delim=$1; shift
	while read -r; do   # Remove leading and trailing whitespaces
		local x=$REPLY; x=${x#"${x%%[! $'\t']*}"}; x=${x%"${x##*[! $'\t']}"}; REPLY=$x
		case $REPLY in '#'*) continue;; esac # comment
		[[ -z "$REPLY" ]] && continue
		[[ "$REPLY" == $REPLY_EOF ]] && return

		local id= cmd=$REPLY
		if [[ -n "$delim" ]]; then
			id=${REPLY%%$delim*}
			cmd=${REPLY#"$id$delim"}
			[[ "$id" == "$REPLY" ]] && echo "error: can't parse task id from '$REPLY' with delim '$delim'" >&2 && return 1
			x=$id;  x=${x%"${x##*[! $'\t']}"}; id=$x
			x=$cmd; x=${x#"${x%%[! $'\t']*}"}; cmd=$x
		fi
		# make sure $cmd is not empty
		if [[ -n "$cmd" ]]; then
			REPLY=$id$ARG_DELIM$cmd
			return
		fi
	done
	REPLY=
}

jobsRunTasks()
{
#	local -
	set -eu

	local taskTxt= delim= tempPath=. logLevel= runMax=1 userText= userFlags=
	# set all 'kw' args to "-k v" form (accepted input: -kv | -k=v | -k v)
	while [[ $# != 0 ]]; do
		local i=$1 v; shift
		case $i in -*) v=${i:2}; i=${i:0:2}; v=${v#=}; 
			if [[ -z "$v" ]]; then
				[[ $# == 0 ]] && echo "error: argument required for '$i' option" >&2 && return 1
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
			*)	[[ -z "$taskTxt" ]] && { taskTxt=$i; continue; }
				echo "error: unrecognized option $i" >&2 && return 1;
		esac
	done
	[[ -z "$taskTxt" ]] && { echo "error: not task file" >&2 && return 1; }
	[[ ! -f "$taskTxt" ]] && { echo "error: task file $taskTxt does not exist" >&2 && return 1; }

    # set term width
	if [[ -z ${COLUMNS:-} ]]; then
		case ${OS:-} in *_NT) COLUMNS=$(mode.com 'con:' | grep -i Columns: | tr -d ' ' | cut -s -d':' -f2); esac
        [[ -z ${COLUMNS:-} ]] && command -v tput >/dev/null 2>&1 && COLUMNS=$(tput cols)
        [[ -n ${COLUMNS:-} ]] && export COLUMNS
    fi

	# Get last cpu index. We are going to use NCPU-1 cores to run
	if [[ "$runMax" -le 0 ]]; then
		x="$(grep 'processor' /proc/cpuinfo)"; x="${x##* }"; # last cpu index
		if [[ "$runMax" == 0 ]]; then     # all CPUs
			runMax=$(( x + 1 ))
		elif [[ "$runMax" == -1 ]]; then  # all CPUs - 1
			runMax=$x
		else                              # all CPUs + |n| - 1
			[[ "$x" == 0 ]] && runMax=1 || runMax=$((x + 1 - runMax - 1))
		fi
	fi
	[[ "$runMax" -le 0 ]] && { echo "error: can't detect CPU number" >&2 && return 1; }

	mkdir -p "$tempPath"
	tempPath="$(cd "$tempPath" >/dev/null; pwd)"

    debug_log_init master

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
	__jobsDisplay=
    # Count jobs number
	while readNewTask "$delim"; do
		[[ -z "$REPLY" ]] && break
		__jobsDoneMax=$(( __jobsDoneMax + 1 ))
	done <"$taskTxt"

	#
	# Single-threaded
	#
	if [[ $ENABLE_NAMED_PIPE != 1 ]]; then
		while readNewTask "$delim"; do
			[[ -z "$REPLY" ]] && break
			local id=${REPLY%$ARG_DELIM*}
			local cmd=${REPLY#*$ARG_DELIM}
			[[ -n "$id" ]] || { id=$__jobsRawIdx; __jobsRawIdx=$(( __jobsRawIdx + 1 )); }

			__jobsDisplay=$id:$cmd${userFlags:+ $userFlags}
			__jobsRunning=1
			jobsReportProgress

			if ! executeSingleTask "$id" "$cmd" "$userText" "$userFlags"; then
				__jobsDone=$(( __jobsDone + 1 ))
				__jobsErrorCnt=$(( __jobsErrorCnt + 1 ))
				jobsReportTaskFail "$id" 1 "$cmd" >&2
				break;
			fi
			__jobsDone=$(( __jobsDone + 1 ))
		done <"$taskTxt"
		__jobsNoMoreTasks=1
		__jobsRunning=0
		jobsReportProgress
		echo ""
		return $__jobsErrorCnt
	fi

	#
	# Multi-threaded
	#
	jobsOnINT() {
		# most likely stderr is redirected to /dev/null at this moment
		[[ $__jobsInterruptCnt == 0 && $__jobsErrorCnt == 0 ]] && __jobsTermReasonInt=1
		__jobsInterruptCnt=$(( __jobsInterruptCnt + 1 ))
		# unblock everything
		rm -f -- $__jobsStatusPipe # need abspath to a 'pipe' since 'pwd' is unpredictable here
		rm -f -- $__jobsWorkPipe
		if [[ -n "$__jobsPingPid" ]]; then
			{ kill -s TERM $__jobsPingPid && wait $__jobsPingPid || true; } 2>/dev/null
			__jobsPingPid=
		fi
		if [[ -n "$__jobsPid" ]]; then
			{ kill -s KILL $__jobsPid && wait $__jobsPid || true; } 2>/dev/null
			__jobsPid=
		fi
#		[[ $__jobsInterruptCnt -ge 3 ]] && exit 127
		exit 127

		return 0
	}
	jobsOnEXIT() {
		exec 4<&- # hard-coded fd

		rm -f -- $__jobsStatusPipe # need abspath to a 'pipe' since 'pwd' is unpredictable here
		rm -f -- $__jobsWorkPipe

		if [[ -n "$__jobsPingPid" ]]; then
			{ kill -s TERM $__jobsPingPid && wait $__jobsPingPid || true; } 1>/dev/null  2>/dev/null
		fi
		if [[ -n "$__jobsPid" ]]; then
			echo "warn: waiting for unfinished jobs: $__jobsPid"
			{ kill -s TERM $__jobsPid && wait $__jobsPid || true; } >/dev/null
		fi
		# due to previous 'rm' the worker may create file '$__jobsStatusPipe' on status report
		rm -f -- $__jobsStatusPipe

		{ jobsReportProgress; echo ""; }
	}

#	readonly __jobsStatusPipe="$tempPath/pipe_status.$$"
#	readonly __jobsWorkPipe="$tempPath/pipe_work.$$"
    local tempVar=/tmp/vctest
    mkdir -p $tempVar
	readonly __jobsStatusPipe="$tempVar/pipe_status.$$"
	readonly __jobsWorkPipe="$tempVar/pipe_work.$$"

	__jobsPid=

	rm -f -- $__jobsStatusPipe $__jobsWorkPipe
	mkfifo $__jobsStatusPipe
	mkfifo $__jobsWorkPipe

	jobsStartPing .3s
	__jobsPingPid=$!

	trap 'jobsOnINT' INT
	trap 'jobsOnEXIT' EXIT

	exec 4<"$taskTxt" # hard-coded fd

	while [ $__jobsRunning -lt $runMax ]; do

		readNewTask "$delim" <&4
		[[ -z "$REPLY" ]] && break;
		local id=${REPLY%$ARG_DELIM*}
		local cmd=${REPLY#*$ARG_DELIM}
		[[ -n "$id" ]] || { id=$__jobsRawIdx; __jobsRawIdx=$(( __jobsRawIdx + 1 )); }

		jobsStartWorker "$id" "$cmd" "$userText" "$userFlags" 4<&- &
		debug_log master "jobsStartWorker $id pid=$!"

		__jobsPid="$__jobsPid $!"
		__jobsDisplay=$id:$cmd${userFlags:+ $userFlags}
		__jobsRunning=$(( __jobsRunning + 1 ))
	done
	[[ $__jobsRunning -lt $runMax ]] && __jobsNoMoreTasks=1

	setWorkerGone() {
		local pid=$1 x=; shift
		debug_log master "setWorkerGone pid=$pid [start waiting pid]"

		{ wait $pid || true; } 2>/dev/null  # may have already gone

		set -- $__jobsPid; # remove from wait list
		for x; do shift; if [[ $x != $pid ]]; then set -- "$@" $x; fi; done
		__jobsPid="$@"
		__jobsRunning=$((__jobsRunning - 1))		# worker exit

		debug_log master "setWorkerGone pid=$pid [onchain $__jobsPid]"
	}

	while : ; do
		# Until have workers running
		while [[ $__jobsRunning != 0 ]]; do
			jobsReportProgress

			# Check feedback pipe still alived and not get destroyed on interrupt
			[[ ! -e $__jobsStatusPipe ]] && break

            # Single reader, multiple writers
            # https://unix.stackexchange.com/questions/450713/named-pipes-file-descriptors-and-eof/450715#450715
            # https://stackoverflow.com/questions/8410439/how-to-avoid-echo-closing-fifo-named-pipes-funny-behavior-of-unix-fifos/8410538#8410538
            set --
            while read -r 2>/dev/null; do
    			# This is a 'ping' - skip it
    			case $REPLY in ping:*) continue; esac

    			debug_log master "statusUpdate: $REPLY"

    			local pid id status data x
    			x=$REPLY
    			x=${REPLY%%:*}; REPLY=${REPLY#$x:}; pid=$x
    			x=${REPLY%%:*}; REPLY=${REPLY#$x:}; id=$x  # maybe empty
    			x=${REPLY%%:*}; REPLY=${REPLY#$x:}; status=$x
    			data=$x

                local needReply=
    			if [[ -z "$id" ]]; then
                    # Worker exit (maybe interrupted), we have nothing to do with completion status here
                    setWorkerGone $pid 
    			else
    				debug_log master "jobsDone id=$id pid=$pid status=$status"
    
    				__jobsDone=$(( __jobsDone + 1 ))
    				if [[ "$status" != 0 ]]; then
    					setWorkerGone $pid; pid= # worker exit due to task fail
    
    					__jobsErrorCnt=$(( __jobsErrorCnt + 1 ))
    					jobsReportTaskFail "$id" $status "$data" >&2
                    else
                        needReply=1
    				fi
    			fi
                [[ -z $needReply ]] && continue

                set -- "$@" "$pid"
   				debug_log master "enqueue message from pid=$pid, #$# [$@]"
#break
#            done <&5
done <$__jobsStatusPipe
    		jobsReportProgress

            [[ $# != 0 ]] && break # continue waiting message we need to reply
		done

        debug_log master "#$# messages in queue, start reply"

		# Time to leave if no workers alive
		[[ $__jobsRunning == 0 ]] && break;

        local dummy
        for dummy; do
	    	if [[ $__jobsNoMoreTasks == 0 && $__jobsErrorCnt == 0 && $__jobsInterruptCnt == 0 ]]; then
				readNewTask "$delim" <&4
				[[ -z "$REPLY" ]] && __jobsNoMoreTasks=1
			else
				REPLY=
    		fi
			local id=${REPLY%$ARG_DELIM*}    # ok if empty id / cmd
			local cmd=${REPLY#*$ARG_DELIM}   #

			local task;
			# Reply with EOF message if no task was read
			if [[ -z "$cmd" ]]; then
				task=$REPLY_EOF
				__jobsDisplay="no more tasks to schedule"
			else
    			[[ -n "$id" ]] || { id=$__jobsRawIdx; __jobsRawIdx=$(( __jobsRawIdx + 1 )); }
				task=$id:$cmd
				__jobsDisplay=$task${userFlags:+ $userFlags}
			fi
			jobsReportProgress

			debug_log master "newTask[submit]: $task"
    		echo "$task" 2>/dev/null >$__jobsWorkPipe
#    		echo "$task" >&8
			debug_log master "newTask[------]: $task"
        done
	done

	trap - INT
	trap - EXIT 

	# Do cleanup
	jobsOnEXIT || true
}

entrypoint "$@"
