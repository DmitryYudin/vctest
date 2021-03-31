#!/bin/bash

#
# Copyright © 2021 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#

#
# Sourced for local transport, executed as a shell script for remote transport
#
set -eu

executor()
{
    local task=$1; shift

    [[ $task == encdec || $task == encode || $task == decode ]] || { echo "error: unknown task '$task'" >&2 && return 1; }

    export PATH=$(pwd):$PATH

    if [[ $task == encdec || $task == encode ]]; then
        local do_encode=1
        [[ $task == encdec ]] && [[ -f encoded.ts ]] && do_encode=
        
        [[ -n $do_encode ]] && executor_encode
    	date "+%Y.%m.%d-%H.%M.%S" > encoded.ts
    fi
    if [[ $task == encdec || $task == decode ]]; then
        executor_decode
    	date "+%Y.%m.%d-%H.%M.%S" > decoded.ts
    fi
}

cpu_monitor()
{
    wmic() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL=* command wmic "$@"; }
    local pid=$1 winpid
    local start_sec=$SECONDS

    local use_wmic=
    case ${OS:-} in *_NT) use_wmic=1; winpid=$(cat /proc/$pid/winpid) &>/dev/null || return 0; esac
    use_wmic= # msys works fine

    while [[ -d /proc/$pid ]]; do
        if [[ $use_wmic == 1 ]]; then
            # can be empty
            local selector_proc=ThreadCount,KernelModeTime,UserModeTime,ReadOperationCount,ReadTransferCount,WriteOperationCount,WriteTransferCount
            local selector_path=PercentProcessorTime,PercentUserTime
            2>/dev/null wmic process where "processid=$winpid" get $selector_proc /value || true
            2>/dev/null wmic path Win32_PerfFormattedData_PerfProc_Process where "idprocess=$winpid" get $selector_path /value || true
        else
            # https://man7.org/linux/man-pages/man5/procfs.5.html
            { cat /proc/$pid/stat && cat /proc/self/stat; } 2>/dev/null || true
        fi

        [[ -d /proc/$pid ]] || return 0
        local period=1
        [[ $((SECONDS - start_sec)) -gt  10 ]] && period=2
        [[ $((SECONDS - start_sec)) -gt  30 ]] && period=5
        [[ $((SECONDS - start_sec)) -gt  60 ]] && period=10
        [[ $((SECONDS - start_sec)) -gt 120 ]] && period=30
        [[ $period -gt 0 ]] && sleep ${period}s
    done
}

executor_encode()
{
    : ${codecId:?not set}
    : ${encoderExe:?not set}
    : ${encoderArgs:?not set}
    : ${bitstreamFile:?not set}
    : ${monitorCpu:?not set}

    date +%s > encoded_ts_begin

    # temporary hack, for backward compatibility (remove later)
    [[ $codecId == h265demo ]] && echo "" > h265demo.cfg

    local error_code=0 consumedSec=$(date +%s)
    if [[ $monitorCpu != 1 ]] ; then
        
        { echo "yes" | $encoderExe $encoderArgs 1>encoded_log 2>&1; } || error_code=1
        consumedSec=$(( $(date +%s) - consumedSec ))

    else
        echo "yes" | $encoderExe $encoderArgs 1>encoded_log 2>&1 &
        local pid=$!
    
        cpu_monitor $pid >encoded_cpu &
        local pid_mon=$!

        { wait $pid || error_code=$?; } 2>/dev/null
        consumedSec=$(( $(date +%s) - consumedSec ))

        { kill -s TERM $pid_mon && wait $pid_mon || true; } 2>/dev/null
    fi

    if [[ $error_code != 0 ]]; then
        { echo "" && cat encoded_log && echo "error: encoding error (status=$error_code), see logs above" && return 1; } >&2 
    fi
    if [[ ! -f $bitstreamFile ]]; then
        { echo "" && cat encoded_log && echo "error: no bitstream file created, see logs above" && return 1; } >&2
    fi
	local numBytes=$(stat -c %s "$bitstreamFile")
    if [[ $numBytes == 0 ]]; then
        { echo "" && cat encoded_log && echo "error: bitstream file has zero length, see logs above" && return 1; } >&2
    fi

    echo $consumedSec > encoded_sec

    date +%s > encoded_ts_end
}

executor_decode()
{
    : ${originalYUV:?not set}
    : ${bitstreamFile:?not set}
    : ${bitstreamFmt:?not set}
    : ${resolutionWxH:?not set}
    : ${TRACE_HM:?not set}

    date +%s > decoded_ts_begin

	local decodedFile=$(basename $bitstreamFile).yuv

	stat -c %s $bitstreamFile > decoded_bitstream_size

	case $bitstreamFmt in
		h264|h265|vp8|vp9)
	    	ffmpeg -y -loglevel error -i $bitstreamFile $decodedFile

    		ffprobe -v error -show_frames -i $bitstreamFile | tr -d $'\r' > decoded_ffprobe
        ;;
		h266)
            vvdecapp -b $bitstreamFile -o $decodedFile > decoded_vvdec
        ;;
		*) echo "error: can't find decoder for '$bitstreamFmt' format" >&2 && return 1;;
	esac

	# ffmpeg does not accept filename in C:/... format as a filter option
    local log
    local fmtStr="-s $resolutionWxH -pix_fmt yuv420p -f rawvideo"
	if ! log=$(ffmpeg -hide_banner $fmtStr -i $originalYUV $fmtStr -i $decodedFile -lavfi "ssim=decoded_ssim;[0:v][1:v]psnr=decoded_psnr" -f null - ); then
		echo "$log" && return 1
	fi

	case $bitstreamFmt in
		h265)
            if [[ "$TRACE_HM" == 1 ]]; then
    			# hard-coded log filename: 'TraceDec.txt'
	    		TAppDecoder -b $bitstreamFile > /dev/null
                mv TraceDec.txt decoded_trace_hm
            fi
		;;
	esac

	rm -f $decodedFile

    date +%s > decoded_ts_end
}


if [[ "$(basename ${BASH_SOURCE-executor.sh})" == "$(basename $0)" ]]; then
executor "$@"
fi
