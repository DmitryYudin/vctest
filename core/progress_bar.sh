#!/bin/bash

#
# Copyright © 2021 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#
set -eu

[[ "$(basename ${BASH_SOURCE-progress_bar.sh})" == "$(basename $0)" ]] && PB_SELF_TEST=1 || PB_SELF_TEST=

if [[ -n $PB_SELF_TEST ]]; then
usage()
{
	cat	<<-'EOT'
One-line progress bar for the sourcing into bash script

    PB_init $tasksNum;          # argument is optional

    PB_set_total $tasksNum      # optional

    for task in @tasks; do
        PB_set_message "$task"  # optional

        PB_increase_running

        PB_report_progress      # any time, any where

        execute "$task"

        PB_increase_done

        if [[ $status != 0 ]]; then
            PB_increase_errors
        fi

        PB_report_progress      # any time, any where
    done

    PB_set_queue_empty          # optional
EOT
}
fi

if [[ -n $PB_SELF_TEST ]]; then
    print_console() { printf "$@"; }
else
    dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
    . "$dirScript/utility_functions.sh"
fi

PB_init()
{
    PB_START_SEC=$SECONDS
    PB_NO_MORE_INPUT=       # all tasks scheduled
    PB_NUM_EXEC=0           # executing now
    PB_NUM_DONE=0           # completed with any exit_status
    PB_NUM_TOTAL=${1:-}
    PB_ERR_COUNT=0          # task errors
    PB_INT_COUNT=0          # script interrupts
    PB_term_reason=
    PB_MESSAGE=
    PB_SPIN=
}
PB_set_message()
{
    [[ "$*" != $PB_MESSAGE ]] && PB_SPIN=1
    PB_MESSAGE="$*"
}
PB_set_no_more_input()
{
    PB_NO_MORE_INPUT=1;
}
PB_set_total()
{
    PB_NUM_TOTAL=$1;
}
PB_increase_running()
{
    local inc=${1:-1}
    PB_NUM_EXEC=$((PB_NUM_EXEC+inc));
    PB_SPIN=1
}
PB_set_running()
{
    PB_NUM_EXEC=$1;
}
PB_increase_done()
{
    local inc=${1:-1}
    PB_NUM_DONE=$((PB_NUM_DONE+inc));
    PB_SPIN=1
}
PB_increase_errors()
{
    local inc=${1:-1}
    [[ -n $PB_term_reason ]] || PB_term_reason=err
    PB_ERR_COUNT=$((PB_ERR_COUNT+inc))
}
PB_increase_interrupts()
{
    local inc=${1:-1}
    [[ -n $PB_term_reason ]] || PB_term_reason=int
    PB_INT_COUNT=$((PB_INT_COUNT+inc))
}

PB_report_progress()
{
    local symTopDn=$'\xc2\xbf' symUp=$'\xcb\x84' symDn=$'\xcb\x85' symInf=$'\xe2\x88\x9e'
    local symCheck=$'\xe2\x88\x9a' symSun=$'\xe2\x98\xbc' symSmile=$'\xe2\x98\xba' symExcl=$'\xe2\x80\xbc'

    pbar_getStatus() {
    	if [[ -z $PB_NO_MORE_INPUT ]]; then
        	REPLY=$symSun
        else
            [[ $PB_NUM_EXEC != 0 ]] && REPLY=$symSmile || REPLY=$symCheck
        fi
	    [[ $PB_ERR_COUNT == 0 && $PB_INT_COUNT == 0 ]] || REPLY=$symExcl
    }
    pbar_getTimestamp() {
    	local dt=$1; shift
    	local hr=$(( dt/60/60 )) min=$(( (dt/60) % 60 )) sec=$(( dt % 60 ))
	    [[ ${#min} == 1 ]] && min=0$min
    	[[ ${#sec} == 1 ]] && sec=0$sec
	    [[ ${#hr}  == 1 ]] && hr=0$hr
    	REPLY="$hr:$min:$sec"
    }
    pbar_getJobsMax() {
    	if [[ -n $PB_NUM_TOTAL ]]; then
            REPLY=$PB_NUM_TOTAL
        elif [[ -n $PB_NO_MORE_INPUT ]]; then
            REPLY=$(( PB_NUM_DONE + PB_NUM_EXEC )) # estimate
        else
    	    REPLY="   "$symInf # 'printf' does not align unicode characters as expected
        fi
    }
    pbar_getSpinner() { # increase counter every access
        local spin=${1:-}
        [[ -z ${pbar_spinner_pos:-} ]] && pbar_spinner_pos=0
        [[ -z $spin ]] || pbar_spinner_pos=$((pbar_spinner_pos+1))
        local spinner='-\|/'
        local spinner_cnt=${#spinner}
        REPLY=${spinner:$(( pbar_spinner_pos%$spinner_cnt )):1}
    }
    pbar_getLabel() { # increase very second
        local patt=
#       patt="$patt>   ""->  ""--> ""--->""=-->"" =->""  =>""   >""   <"">  <""-> <""--><""=-><"" =><""  ><""  <<"
#       patt="$patt> <<""-><<""=><<"" ><<"" <<<""><<<""<<<<""-<<<""--<<""---<""----"" ---""  --""   -""    "
        patt="$patt<  ><..><oo><oO><oo><oO><oo><oO><-O><--><-->(OO)(OO)(..)(..)(OO)(OO)[00]"
        patt="$patt[00][--][--]:)  :)   :)   :)  :)  :) :-):--):--><-->"
#       patt="$patt[^^][''][^^][''][  ]-][--][-o][oo][oO][OO][O-][--][-=][=-][-=][=-][-[  ] "

        [[ -z ${pbar_amin_pos:-} ]] && pbar_amin_pos=$SECONDS
        local amin_pos=$((SECONDS - pbar_amin_pos))
        local patt_cnt=$(( ${#patt} / 4))
	    REPLY=${patt:$(( 4*(amin_pos%$patt_cnt) )):4}
    }

	local dt=$((SECONDS - PB_START_SEC))
	local status= timestamp= tot= spinner= label=

	pbar_getStatus;                 status=$REPLY
	pbar_getTimestamp $dt;          timestamp=$REPLY
	pbar_getJobsMax;                tot=$REPLY
    pbar_getSpinner $PB_SPIN;       spinner=$REPLY; PB_SPIN=
	pbar_getLabel;                  label=$REPLY

	# replace animation by error info
	if [[ $PB_ERR_COUNT != 0 || $PB_INT_COUNT != 0 ]]; then
		[[ $PB_term_reason == err ]] && label="#E=$PB_ERR_COUNT" || label='INT'
	fi

	local runWidth=1
	[[ $PB_NUM_EXEC -ge 10 ]] && runWidth=2
	[[ $PB_NUM_EXEC -ge 100 ]] && runWidth=3

	print_console "%s %s[%4s/%4s][#%${runWidth}s]%s%4s%s\r" $timestamp \
		"$status" "$PB_NUM_DONE" "$tot" "$PB_NUM_EXEC" "$spinner" "$label" "${PB_MESSAGE:+:$PB_MESSAGE}"
}

if [[ -n $PB_SELF_TEST ]]; then
entrypoint()
{
    for REPLY; do case $REPLY in -h|--help) usage; return;; esac ; done

    test() {
        local period_sec=$1; shift
        local callback=$1; shift
        local start_sec=$SECONDS
        PB_init; PB_START_SEC=$((SECONDS - 11*60*60 + 60*60 + 5))
        local i=0; actions="$@";
        while : ; do
            i=$((i+1))
            sleep .3s
            $callback $i
            PB_report_progress
            local dt=$((SECONDS - start_sec))
            [[ $dt -lt $period_sec ]] || break
        done
    }

    trap 'echo ' EXIT

    DURATION=2; cb() { 
        PB_set_message "interrupted [$DURATION sec]"
        PB_increase_interrupts
    }; [[ $DURATION == 0 ]] || { test $DURATION cb && echo ""; }

    DURATION=1; cb() { 
        PB_set_message "error display [$DURATION sec]"
        PB_increase_errors     
    }; [[ $DURATION == 0 ]] || { test $DURATION cb && echo ""; }

    DURATION=1; cb() { 
        PB_set_message "error + interrupt = error [$DURATION sec]"
        PB_increase_errors
        PB_increase_interrupts
    }; [[ $DURATION == 0 ]] || { test $DURATION cb && echo ""; }

    DURATION=1; cb() { 
        PB_set_message "interrupt + error = interrupt [$DURATION sec]"
        PB_increase_interrupts
        PB_increase_errors
    }; [[ $DURATION == 0 ]] || { test $DURATION cb && echo ""; }

    DURATION=2; cb() { 
        PB_set_message "queue empy status [$DURATION sec]"
        PB_set_no_more_input
        PB_increase_running
    }; [[ $DURATION == 0 ]] || { test $DURATION cb && echo ""; }

    DURATION=2; cb() { 
        PB_set_message "known total tasks number [$DURATION sec]"
        PB_increase_running $i
        PB_set_total 100
    }; [[ $DURATION == 0 ]] || { test $DURATION cb && echo ""; }

    DURATION=4; cb() { 
        PB_set_message "increase completion counter [$DURATION sec]"
        PB_increase_running;
        PB_set_total 100; 
        PB_increase_done 2; 
    }; [[ $DURATION == 0 ]] || { test $DURATION cb && echo ""; }

    DURATION=30; cb() { 
        PB_set_message "animation test [$DURATION sec]"
        PB_set_total 100
        PB_set_no_more_input
        PB_increase_running
    }; [[ $DURATION == 0 ]] || { test $DURATION cb && echo ""; }
}

entrypoint "$@"
fi
