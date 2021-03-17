#!/bin/bash
#
# Copyright © 2019 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#
set -eu -o pipefail

dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
. "$dirScript/message_q.sh"
. "$dirScript/progress_bar.sh"

ENABLE_NAMED_PIPE=${ENABLE_NAMED_PIPE:-1}

usage()
{
	cat<<-\EOT
	Parallel task executor in Bash.

	This script reads a text file (testplan), where each line is a simple shell
	command. For each line, the substitution of shell variables is performed,
	followed by the execution of the resulting expression. No more commands are
	scheduled if execution failed. Instead, the stdout/stderr logs are printed
	on a screen, all scheduled commands are waited to complete and script
	terminates with nonzero status.

	Normally, only execution progress is displayed. Each task is executed with
	the output streams redirected to a '$tempPath/$id.std{out,err}.log' files
	where 'id' is an auto incremented task number.

	Usage:
	    rpte.sh <testplan> [options]

	Options:
	    -h,--help    Print this help
	       --test    Run test
	    -p <path>    Temporary path for stdout/stderr logs
	    -j <n>       Maximum number of tasks running in parallel (default: 1)
	                    =  0 - all CPUs
	                    = -1 - all CPUs - 1    (i.e. reserve one core)
	                    <  0 - all CPUs + |n|
	    -t <text>    Text message to append to stdout log for every executed task
	    -f <flags>   Flags to append to a command line for every task
EOT
# 'R' for 'reliable'
}

check_msys_ver_lt() # !msys:REPLY='' msys:ver<=maj.min => REPLY=1/0
{
    local maj_max=${1%%.*}
    local min_max=${1#$maj_max}; min_max=${min_max#.}
    [[ -z "$min_max" ]] && min_max=0
    case $(uname -a) in MSYS_NT-*) :;; *) REPLY=; return;; esac
    REPLY=$(uname -r); REPLY=${REPLY%%-*}
    local maj=${REPLY%%.*}; REPLY=${REPLY#$maj.}
    local min=${REPLY%%.*}
    REPLY=0
    [[ $maj -lt $maj_max ]] && REPLY=1 || [[ $min -lt $min_max ]] && REPLY=1
    return 0
}

entrypoint()
{
	local BUSYBOX=$(cat --help 2>&1 | head -1 | grep BusyBox) || true
	[[ -n "$BUSYBOX" ]]             && ENABLE_NAMED_PIPE=0 # not supported
	[[ -n "${KSH_VERSION:-}" ]]     && ENABLE_NAMED_PIPE=0 # not supported (Android shell)
	[[ -n "${WSL_DISTRO_NAME:-}" ]] && ENABLE_NAMED_PIPE=0 # broken
    check_msys_ver_lt 3.1
    if [[ "$REPLY" == 1 ]]; then
        echo "Please, update msys to version 3.1 or above:"\
             "http://repo.msys2.org/distrib/msys2-x86_64-latest.tar.xz"
        ENABLE_NAMED_PIPE=0
    fi
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
	else
        local i=0 N=20 self=$0
		rm -rf tmp
        echo "Scheduling $((N*10)) tasks..."
        printf -v REPLY '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n # comment' \
             true true true true true true true true true true
        while [[ $i -lt $N ]]; do
            i=$((i+1))
            echo "$REPLY"
        done > tasks.txt

        local self=$0
		if "$self" -p tmp -j4 tasks.txt; then
            echo Success
        else
            echo "Complete with error"
            return 1
        fi
        rm -f tasks.txt
	fi
}

# Progress reported to stdout (since report progress on interrupt)
# Errors are printed to stderr
readonly REPLY_EOF='-'

# Ping self to report execution progress till the statusPIPE opened
jobsStartPing()
{
	[[ $ENABLE_NAMED_PIPE != 1 ]] && return 1

	local period=$1
	{
		trap 'return 0' INT

        MQ_slave_create

        while MQ_slave_write_status "ping::0:"; do
			sleep $period
        done
	} </dev/null 1>/dev/null 2>/dev/null &
}

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

	# Prepare command line
	eval 'set -- $cmd'
	for REPLY; do shift;
		x=$(eval printf "%s" "$REPLY") # can't use 'echo' here due to '-e'
		set -- "$@" "$REPLY"
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
debug_log_master() { debug_log master "$@"; }
debug_log_worker() { debug_log worker "$@"; }

jobsStartWorker()
{
	[[ $ENABLE_NAMED_PIPE != 1 ]] && return 1

	set -eu

	local userText=$1; shift

	local runningTaskId=
	local runningTaskCmd=
    local workDone=

    MQ_slave_create debug_log_worker
    MQ_slave_init_taskPump

	onWorkerExit() {
		local error_code=0
		[[ -n "$runningTaskId" ]] && error_code=1
		[[ -n "$workDone" ]] && error_code=0

        debug_log_worker "exit: id=$runningTaskId workDone=$workDone error_code=$error_code"

		# open pipe first to avoid 'echo: write error: Broken pipe' message
        MQ_slave_write_status "$BASHPID:id=$runningTaskId:$error_code:$runningTaskCmd"

        debug_log_worker "Done"
		exit $error_code
	}
	trap onWorkerExit EXIT

	while : ; do

        MQ_slave_read_task

		local id=${REPLY%%:*} cmd=${REPLY#*:}
        id=${id#id=}
        if [[ "$cmd" == $REPLY_EOF ]]; then
        	debug_log_worker "no more tasks: $cmd"
            break
		fi

		runningTaskId=$id
		runningTaskCmd=$cmd
    	debug_log_worker "E id=$id cmd=[$cmd]"
       	executeSingleTask "$id" "$cmd" "$userText"
		runningTaskId=
		runningTaskCmd=

        MQ_slave_write_status "$BASHPID:id=$id:0:$cmd"

    done
    debug_log_worker "exit main loop"

    workDone=1
    exit 0
}

# unicode characters
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

tempPath=.
jobsRunTasks()
{
	set -eu

	local taskTxt= logLevel= runMax=1 userText= userFlags=
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

    PB_init
    debug_log_init master

	__jobsRawIdx=0
	__jobsRunning=0
	__jobsLogLevel=1
	__jobsStderrToStdout=${1:-0}
	__jobsErrorCnt=0
	__jobsInterruptCnt=0
	__jobsNoMoreTasks=0
	__jobsDone=0
	__jobsStartSec=$SECONDS

    # Count jobs number
    local testPlan=$tempPath/tasks.$$.txt
    local tasksTotal=0
    rm -f $testPlan
	while read -r; do   # Remove leading and trailing whitespaces
		local x=$REPLY; x=${x#"${x%%[! $'\t']*}"}; x=${x%"${x##*[! $'\t']}"}; REPLY=$x
		case $REPLY in '#'*) continue;; esac # comment
		[[ -z "$REPLY" ]] && continue
		tasksTotal=$(( tasksTotal + 1 ))
        echo "$REPLY${userFlags:+ $userFlags}"
	done <$taskTxt >$testPlan

    PB_set_total $tasksTotal

	#
	# Single-threaded
	#
	if [[ $ENABLE_NAMED_PIPE != 1 ]]; then
		while read -r; do
			[[ -z "$REPLY" ]] && break
            local id=$__jobsRawIdx; __jobsRawIdx=$(( __jobsRawIdx + 1 ))
			local cmd=$REPLY


			__jobsRunning=1
            PB_set_running 1
            PB_set_message "$cmd"
            PB_report_progress

			if ! executeSingleTask $id "$cmd" "$userText"; then
				__jobsDone=$(( __jobsDone + 1 ))
                PB_increase_done

				__jobsErrorCnt=$(( __jobsErrorCnt + 1 ))
                PB_increase_errors

				jobsReportTaskFail "$id" 1 "$cmd" >&2
				break;
			fi
			__jobsDone=$(( __jobsDone + 1 ))
            PB_increase_done
		done <$testPlan
		__jobsNoMoreTasks=1
        PB_set_no_more_input

		__jobsRunning=0
        PB_set_running 0
		PB_report_progress
		echo ""
		return $__jobsErrorCnt
	fi

	#
	# Multi-threaded
	#
	jobsOnINT() {
		# most likely stderr is redirected to /dev/null at this moment
		__jobsInterruptCnt=$(( __jobsInterruptCnt + 1 ))
        PB_increase_interrupts

		# unblock everything
        MQ_master_destroy

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

        MQ_master_destroy

		if [[ -n "$__jobsPingPid" ]]; then
			{ kill -s TERM $__jobsPingPid && wait $__jobsPingPid || true; } 1>/dev/null  2>/dev/null
		fi
		if [[ -n "$__jobsPid" ]]; then
			debug_log_master "waiting for unfinished jobs: $__jobsPid"
			{ kill -s TERM $__jobsPid && wait $__jobsPid || true; } >/dev/null
		fi

		# due to previous 'rm' the worker may create file with a pipe name on status report
        MQ_master_destroy

		{ PB_report_progress; echo ""; }

        local exit_status=0
        [[ $__jobsInterruptCnt != 0 || $__jobsErrorCnt != 0 ]] && exit_status=1
        exit $exit_status
	}

	__jobsPid=

    MQ_master_create debug_log_master

	jobsStartPing .3s
	__jobsPingPid=$!

    MQ_master_init_statusPump

	trap 'jobsOnINT' INT
	trap 'jobsOnEXIT' EXIT

	exec 4<$testPlan # hard-coded fd
	while [[ $__jobsRunning -lt $runMax ]]; do
        REPLY=
		read -r -u 4 || true
		[[ -z "$REPLY" ]] && break;
		local id=$__jobsRawIdx; __jobsRawIdx=$(( __jobsRawIdx + 1 ));
		local cmd=$REPLY

		jobsStartWorker "$userText" 4<&- &
		debug_log_master "jobsStartWorker $id pid=$!"

		__jobsPid="$__jobsPid $!"
		__jobsRunning=$(( __jobsRunning + 1 ))

        PB_increase_running
        PB_set_message "$cmd"
        PB_report_progress

        MQ_master_write_task "id=$id:$cmd"
	done
	[[ $__jobsRunning -lt $runMax ]] && __jobsNoMoreTasks=1 && PB_set_no_more_input

	setWorkerGone() {
		local pid=$1; shift
		debug_log_master "setWorkerGone pid=$pid [start waiting pid]"

		{ wait $pid || true; } 2>/dev/null  # may have already gone

		set -- $__jobsPid; # remove from wait list
		for REPLY; do shift; if [[ $REPLY != $pid ]]; then set -- "$@" $REPLY; fi; done
		__jobsPid="$@"
		__jobsRunning=$((__jobsRunning - 1))		# worker exit
        PB_increase_running -1

		debug_log_master "setWorkerGone pid=$pid [onchain $__jobsPid]"
	}

    local id_done=0
	while : ; do
		# Until have workers running
		while [[ $__jobsRunning != 0 ]]; do

            # Single reader, multiple writers
            # https://unix.stackexchange.com/questions/450713/named-pipes-file-descriptors-and-eof/450715#450715
            # https://stackoverflow.com/questions/8410439/how-to-avoid-echo-closing-fifo-named-pipes-funny-behavior-of-unix-fifos/8410538#8410538
            REPLY=
            while [[ -z "$REPLY" ]]; do
                MQ_master_read_status
    			case $REPLY in ping:*) PB_report_progress; REPLY=; esac
            done

            local msg=$REPLY
            REPLY=$msg
			local pid id status data x
			x=${REPLY%%:*}; REPLY=${REPLY#$x:}; pid=$x
			x=${REPLY%%:*}; REPLY=${REPLY#$x:}; id=$x  # maybe empty
			x=${REPLY%%:*}; REPLY=${REPLY#$x:}; status=$x
			data=$REPLY
            id=${id#id=}
			if [[ -z "$id" ]]; then
                # Worker exit (maybe interrupted), we have nothing to do with completion status here
                setWorkerGone $pid
			else
				debug_log_master "jobsDone id=$id pid=$pid status=$status"

				__jobsDone=$(( __jobsDone + 1 ))
                PB_increase_done

				if [[ "$status" != 0 ]]; then
					setWorkerGone $pid; # worker exit due to task fail

					__jobsErrorCnt=$(( __jobsErrorCnt + 1 ))
                    PB_increase_errors

					jobsReportTaskFail "$id" $status "$data" >&2
                else
                    break # must reply on this message
				fi
			fi
            PB_report_progress
		done

        debug_log_master "start reply"

		# Time to leave if no workers alive
		[[ $__jobsRunning == 0 ]] && break;

        REPLY=
	    if [[ $__jobsNoMoreTasks == 0 && $__jobsErrorCnt == 0 && $__jobsInterruptCnt == 0 ]]; then
			read -r -u 4 || true
			[[ -z "$REPLY" ]] && __jobsNoMoreTasks=1 && PB_set_no_more_input
    	fi
		local id= cmd=
		if [[ -z "$REPLY" ]]; then
			id=$id_done
			cmd=$REPLY_EOF
			id_done=$(($id_done+1))
		else
    		id=$__jobsRawIdx; __jobsRawIdx=$(( __jobsRawIdx + 1 ));
            cmd=$REPLY
		fi

        PB_set_message "$cmd"
		PB_report_progress

        MQ_master_write_task "id=$id:$cmd"
	done

    debug_log_master "exit main loop"
}

entrypoint "$@"
