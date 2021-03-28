#!/bin/bash

#
# Copyright © 2021 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#

#
# This script is for a sourcing, a seft-test is executed if running alone.
#
# Usage:
#
#   . ./condor.sh
#
#   # Set job name
#   CONDOR_setBatchname $(date "+%Y.%m.%d-%H.%M.%S")
#
#   for task in $tasks; do
#
#       # Jump into a task-specific directory
#       mkdir -p $dirOut/$task && cd $dirOut/$task
#
#       # Create condor-task in push it into the queue
#       CONDOR_makeTask "$executable" "$arguments" "$files" > task.sub
#       CONDOR_submit task.sub > submit.log
#
#       cd -
#   done
#
#   CONDOR_wait
#
set -eu

[[ "$(basename ${BASH_SOURCE-condor.sh})" == "$(basename $0)" ]] && CNDR_SELF_TEST=1 || CNDR_SELF_TEST=

CONDOR_setBatchname()
{
    if ! command -p -v condor_version >/dev/null; then
        echo "error: condor not found" >&2
        return 1
    fi
    export CNDR_batchname=$1; shift
    export CNDR_killfile=$(pwd)/kill_session_${CNDR_batchname////_}.sh

    echo "condor_rm -const JobBatchName==\\\"$CNDR_batchname\\\"" >$CNDR_killfile
    chmod 777 "$CNDR_killfile"
}

CONDOR_setCPU()
{
    export CNDR_request_cpus=$1
}
CONDOR_setDisk()
{
    export CNDR_request_disk=$1
}
CONDOR_setMemory()
{
    export CNDR_request_memory=$1
}

CONDOR_submit()
{
    local taskfile=$1
    [[ -z "$CNDR_batchname" ]] && echo "error: batch name not set" >&2 && return 1
    condor_submit -batch-name "$CNDR_batchname" -queue 1 -terse $taskfile
}

CONDOR_wait()
{
    condor_parse_status() {
        local data=$1 request=$2
        local sum_U=0 sum_R=0 sum_I=0 sum_X=0 sum_C=0 sum_H=0 sum_E=0
        local IFS=$'\n'
        for REPLY in $data; do
            case $REPLY in
                0) sum_U=$((sum_U + 1));; # Unexpanded
                1) sum_I=$((sum_I + 1));; # Idle
                2) sum_R=$((sum_R + 1));; # Running
                3) sum_X=$((sum_X + 1));; # Removed         # remove from queue or killed (if running) with condor_rm
                4) sum_C=$((sum_C + 1));; # Completed
                5) sum_H=$((sum_H + 1));; # Held            # job will not be scheduled to run until it is released (condor_hold, condor_release)
                6) sum_E=$((sum_E + 1));; # Submission_err
            esac
        done
        case $request in
            all)      REPLY=$((sum_U + sum_R + sum_I + sum_X + sum_C + sum_H + sum_E));;
            idle)     REPLY=$sum_I;;
            hold)     REPLY=$sum_H;;
            run)      REPLY=$sum_R;;
            complete) REPLY=$sum_C;;
            *) error "error: unrecognized CONDOR_STATUS=$request" >&2; return 1;
        esac
    }
    condor_getTimestamp() {
        local dt=$1; shift
        local hr=$(( dt/60/60 )) min=$(( (dt/60) % 60 )) sec=$(( dt % 60 ))
        [[ ${#min} == 1 ]] && min=0$min
        [[ ${#sec} == 1 ]] && sec=0$sec
        [[ ${#hr}  == 1 ]] && hr=0$hr
        REPLY="$hr:$min:$sec"
    }
    local startSec=$SECONDS error_code=0

    while :; do
        local exec_q=$(condor_q       -format "%d\n" JobStatus -const "JobBatchName==\"$CNDR_batchname\"")
        local hist_q=$(condor_history -format "%d\n" JobStatus -const "JobBatchName==\"$CNDR_batchname\"")

        condor_parse_status "$exec_q" all;      local exec_tot=$REPLY
        condor_parse_status "$exec_q" idle;     local wait_idle=$REPLY
        condor_parse_status "$exec_q" hold;     local wait_hold=$REPLY
        condor_parse_status "$exec_q" run;      local wait_run=$REPLY
        condor_parse_status "$hist_q" all;      local done_tot=$REPLY
        condor_parse_status "$hist_q" complete; local done_ok=$REPLY
        local wait_tot=$((wait_idle + wait_hold + wait_run));
        local done_err=$((done_tot - done_ok))
        local tot=$((wait_tot + done_tot))
        local dt=$((SECONDS - startSec)) timestamp=
        condor_getTimestamp $dt; timestamp=$REPLY

        printf "%s[%4s/%4s]#%s|E=%s Idle=%-3s Hold=%-3s %s\r" \
            $timestamp $done_tot $tot $wait_run $done_err $wait_idle $wait_hold "$CNDR_batchname"
        [[ $done_err != 0 ]] && error_code=1 && break;
        [[ $wait_tot == 0 ]] && break;
        sleep 1s
    done
    echo ""
    rm -f "$CNDR_killfile"

    if [[ $error_code != 0 ]]; then
        local exec_q num_before num_after=0
        exec_q=$(condor_q       -format "%d\n" JobStatus -const "JobBatchName==\"$CNDR_batchname\"")
        condor_parse_status "$exec_q" all; num_before=$REPLY
        if [[ $num_before != 0 ]]; then
            condor_rm -const "JobBatchName==\"$JobBatchName\"" 2>/dev/null || true
            exec_q=$(condor_q       -format "%d\n" JobStatus -const "JobBatchName==\"$CNDR_batchname\"")
            condor_parse_status "$exec_q" all; num_after=$REPLY
        fi
        echo "Complete with errors, $((num_before - num_after)) jobs were killed, $num_after jobs in a queue marked for delete"
        return 1
    fi
}

CONDOR_makeTask() # exe args files="file1, file2, ..." environment="name1=val1; name2=var2; ..."
{
    local executable=$1; shift
    local arguments=$1; shift
    local input_files=$1; shift
    local environment=$1; shift
    local tag=${1-} prefix=
    [[ -n "$tag" ]] && prefix=${tag:+${tag}_}

    local prefix=${tag:+${tag}_}condor

    cat <<-EOT
    universe=vanilla
    log=${prefix}_cluster.log

    arguments=$arguments
    environment=$environment

    # input
    transfer_input_files=$input_files
    should_transfer_files=YES
    when_to_transfer_output=ON_EXIT

    # do not capture local environment
    getenv=False

    # exec
    executable=$executable
    transfer_executable=True

    # stdin
    input=/dev/null
    stream_input=False

    # stdout
    output=${prefix}_stdout.log
    stream_output=False

    # stderr
    error=${prefix}_stderr.log
    stream_error=False

    # resources
    request_cpus=${CNDR_request_cpus:-1}
    request_disk=${CNDR_request_disk:-3G}
    request_memory=${CNDR_request_memory:-500M}
EOT
}

if [[ -n $CNDR_SELF_TEST ]]; then
entrypoint()
{
    pushd() { command pushd "$@" >/dev/null; }
    popd() { command popd "$@" >/dev/null; }

    local timestamp=$(date "+%Y.%m.%d-%H.%M.%S")

    CONDOR_setBatchname msk-$timestamp

    mkdir -p tmp # consider as a test root
    pushd tmp
    local executable=$(pwd)/task.sh

    echo "#!/bin/bash" >$executable
    cat<<-'EOT' >>$executable
        echo "----------------------------- pwd/PWD"
        echo $PWD
        pwd

        echo "----------------------------- Directory content:"
        ls .

        echo "----------------------------- Environment:"
        env

        echo "----------------------------- Environment passed:"
        echo "ENV[1]=$ENV1"
        echo "ENV[2]=$ENV2"

        echo "----------------------------- Arguments:"
        for i; do echo "arg: $i"; done

        echo "Hello, stderr!" >&2
        echo "Hello, output file!" >out.txt

        sleep 2s

        echo "----------------------------- $1:"
        cat $1
        echo "----------------------------- in1.txt:"
        cat in1.txt
        echo "----------------------------- in2.txt:"
        cat in2.txt
EOT
    chmod 777 $executable

    mkdir -p vectors
    pushd vectors
    local dirVec=$(pwd)
    echo "Hello, I'm input-1!" >in1.txt
    echo "Hello, I'm input-2!" >in2.txt
    local files="$dirVec/in1.txt, $dirVec/in2.txt"
    popd

    local dirOut=$timestamp

    local id=0
    while [[ $id -lt 8 ]]; do
        local arguments="in1.txt arg1 arg2 $id"

        mkdir -p $dirOut/$id
        pushd $dirOut/$id
        CONDOR_makeTask "$executable" "$arguments" "$files" > task.sub
        CONDOR_submit task.sub > submit.log
        popd
        id=$((id + 1))
    done

    echo Submitted

    trap 'echo' EXIT
    CONDOR_wait
    trap - EXIT
}

entrypoint "$@"

fi
