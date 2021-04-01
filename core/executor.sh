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

PERF_ID=
start_cpu_monitor()
{
	local encExe=$1; shift
	local name=${encExe##*/}; name=${name%.*}

	local cpu_monitor_type=posix; case ${OS:-} in *_NT) cpu_monitor_type=windows; esac
	if [[ $cpu_monitor_type == windows ]]; then
		typeperf '\Process('$name')\% Processor Time' &
		PERF_ID=$!
	else
		# TODO: posix compatible monitor
		:
	fi
}
stop_cpu_monitor()
{
	[[ -z "$PERF_ID" ]] && return 0
	{ kill -s INT $PERF_ID && wait $PERF_ID; } || true 
	PERF_ID=
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

    if [[ $monitorCpu == 1 ]] ; then
        # Start CPU monitor (TODO: make sure we preserve original handler)
        trap 'stop_cpu_monitor 1>/dev/null 2>&1' EXIT
        start_cpu_monitor "$remoteExe" > encoded_cpu
    fi

    local consumedSec=$(date +%s)

    if ! { echo "yes" | $encoderExe $encoderArgs; } 1>encoded_log 2>&1 || [ ! -f $bitstreamFile ]; then
        echo "" # newline if stderr==tty
        cat encoded_log >&2
        echo "error: encoding error, see logs above" >&2
        return 1
    fi

    consumedSec=$(( $(date +%s) - consumedSec ))

    if [[ $monitorCpu == 1 ]] ; then
        echo $consumedSec > encoded_sec

        # Stop CPU monitor
        stop_cpu_monitor
        trap - EXIT
    fi

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
