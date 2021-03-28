#!/bin/bash

set -eu

executor()
{
    local task=$1; shift

    [[ $task == encdec || $task == encode || $task == decode ]] || { echo "error: unknown task '$task'" >&2 && return 1; }

    export PATH=$(pwd):$PATH

    local removeOriginalYUV=
    if [[ $task == encdec ]]; then
        # condor + no shared files
        if [[ $(basename $originalYUV) == $originalYUV ]]; then
            local originalNut=${originalYUV%.*}.nut
            if [[ ! -f $originalYUV && -f $originalNut ]]; then
                ffmpeg -i $originalNut $originalYUV >/dev/null
                trap "rm -f $originalYUV" EXIT
                removeOriginalYUV=1
            fi
        fi
    fi

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

    if [[ $removeOriginalYUV == 1 ]]; then
        trap - EXIT
        rm -f $originalYUV
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
}

executor_decode()
{
    : ${originalYUV:?not set}
    : ${bitstreamFile:?not set}
    : ${bitstreamFmt:?not set}
    : ${resolutionWxH:?not set}
    : ${TRACE_HM:?not set}

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
	if ! log=$(ffmpeg -hide_banner -s $resolutionWxH -i $originalYUV -s $resolutionWxH -i $decodedFile -lavfi "ssim=decoded_ssim;[0:v][1:v]psnr=decoded_psnr" -f null - ); then
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
}


if [[ "$(basename ${BASH_SOURCE-executor.sh})" == "$(basename $0)" ]]; then
executor "$@"
fi
