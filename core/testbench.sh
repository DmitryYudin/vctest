set -eu -o pipefail

dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
. "$dirScript/utility_functions.sh"
. "$dirScript/codec.sh"

PRMS="28 34 39 44"
REPORT=report.log
REPORT_KW=${REPORT%.*}.kw
CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo h264demo"
PRESETS=
THREADS=1
VECTORS="
	$dirScript/../vectors/akiyo_cif.yuv
	$dirScript/../vectors/foreman_cif.yuv
"
DIR_OUT='out'
TESTPLAN=testplan.txt
NCPU=0
readonly ffmpegExe=$dirScript/../'bin/ffmpeg.exe'
readonly ffprobeExe=$dirScript/../'bin/ffprobe.exe'

usage()
{
	cat	<<-EOF
	Usage:
	    $(basename $0) [opt]

	Options:
	    -h|--help     Print help.
	    -i|--input    Input YUV files. Multiple '-i vec' allowed.
	    -d|--dir      Output directory. Default: "$DIR_OUT"
	    -o|--output   Report path.
	    -c|--codec    Codecs list. Default: "$CODECS".
	    -t|--threads  Number of threads to use
	    -p|--prms     Bitrate (kbps) or QP list. Default: "$PRMS".
	                  Values less than 60 considered as QP.
	       --preset   Codec-specific list of 'preset' options (default: marked by *):
	                  ashevc:   *1 2 3 4 5 6
	                  x265:     *ultrafast  superfast veryfast  faster fast medium slow slower veryslow placebo
	                  kvazaar:  *ultrafast  superfast veryfast  faster fast medium slow slower veryslow placebo
	                  kingsoft:  ultrafast *superfast veryfast         fast medium slow        veryslow placebo
	                  intel_sw:                       veryfast *faster fast medium slow slower veryslow
	                  intel_hw:                       veryfast  faster fast medium slow slower veryslow
	                  h265demo: 6 *5 4 3 2 1
	                  h264demo: N/A
	    -j|--ncpu     Number of encoders to run in parallel. The value of '0' will run as many encoders as many
	                  CPUs available. Default: $NCPU
	                  Note, execution time based profiling data (CPU consumption and FPS estimation) is not
	                  available in parallel execution mode.
	       --hide     Do not print legend and header
	EOF
}

entrypoint()
{
	local cmd_vec= cmd_report= cmd_codecs= cmd_threads= cmd_prms= cmd_presets= cmd_dirOut= cmd_ncpu= cmd_endofflags=
	local hide_banner=
	while [ "$#" -gt 0 ]; do
		local nargs=2
		case $1 in
			-h|--help)		usage && return;;
			-i|--in*) 		cmd_vec="$cmd_vec $2";;
			-d|--dir)		cmd_dirOut=$2;;
			-o|--out*) 		cmd_report=$2;;
			-c|--codec*) 	cmd_codecs=$2;;
			-t|--thread*)   cmd_threads=$2;;
			-p|--prm*) 		cmd_prms=$2;;
			   --pre*) 		cmd_presets=$2;;
			-j|--ncpu)		cmd_ncpu=$2;;
			   --hide)		hide_banner=1; nargs=1;;
			   --)			cmd_endofflags=1; nargs=1;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift $nargs
		[ -n "$cmd_endofflags" ] && break
	done
	[ -n "$cmd_dirOut" ] && DIR_OUT=$cmd_dirOut
	[ -n "$cmd_report" ] && REPORT=$cmd_report && REPORT_KW=${REPORT%.*}.kw
	[ -n "$cmd_vec" ] && VECTORS=${cmd_vec# }
	[ -n "$cmd_codecs" ] && CODECS=$cmd_codecs
	[ -n "$cmd_threads" ] && THREADS=$cmd_threads
	[ -n "$cmd_prms" ] && PRMS=$cmd_prms
	[ -n "$cmd_presets" ] && PRESETS=$cmd_presets
	[ -n "$cmd_ncpu" ] && NCPU=$cmd_ncpu
	PRESETS=${PRESETS:--}
	# for multithreaded run, run in single process to get valid cpu usage estimation
	[ $THREADS -gt 1 ] && NCPU=1

	if [ -n "$cmd_endofflags" ]; then
		echo "exe: $@"
		"$@"
		return $?
	fi

	mkdir -p "$DIR_OUT" "$(dirname $REPORT)"

	# Remove non-existing and set abs-path
	vectors_verify $VECTORS; VECTORS=$REPLY

	# Remove codecs we can't run
	codec_verify $CODECS; CODECS=$REPLY

	local startSec=$SECONDS

	#
	# Scheduling
	#
	progress_begin "[1/5] Scheduling..." "$PRMS" "$VECTORS" "$CODECS" "$PRESETS"

	local optionsFile=options.txt
	prepare_optionsFile "$optionsFile"

	local encodeList= decodeList= parseList= reportList=
	while read info; do
		local encCmdArgs
		dict_getValueEOL "$info" encCmdArgs; encCmdArgs=$REPLY
		info=${info%%encCmdArgs:*} # do not propogate cmdArgs

		local encExeHash encCmdHash
		dict_getValue "$info" encExeHash; encExeHash=$REPLY
		dict_getValue "$info" encCmdHash; encCmdHash=$REPLY
		local outputDirRel="$encExeHash/$encCmdHash"
		local outputDir="$DIR_OUT/$outputDirRel"

		local encode=false
		if [ ! -f "$outputDir/encoded.ts" ]; then
			encode=true
		elif [ $NCPU -eq 1 -a ! -f "$outputDir/cpu.log" ]; then
			encode=true  # update CPU log
		fi
		if $encode; then
			# clean up target directory if we need to start from a scratch
			rm -rf "$outputDir"		# this alos force decoding and parsing
			mkdir -p "$outputDir"

			local codecId= src= dst= encCmdSrc= encCmdDst=
			dict_getValue "$info" codecId; codecId=$REPLY
			dict_getValue "$info" encExe; encExe=$REPLY
			dict_getValue "$info" src; src=$REPLY
			dict_getValue "$info" dst; dst=$REPLY

			codec_cmdSrc $codecId "$src"; encCmdSrc=$REPLY
			codec_cmdDst $codecId "$dst"; encCmdDst=$REPLY

			# readonly kw-file will be used across all processing stages
			echo "$info" > $outputDir/info.kw

			local cmd="$encExe $encCmdArgs $encCmdSrc $encCmdDst"
			echo "$cmd" > $outputDir/cmd

			encodeList="$encodeList $outputDirRel"
		fi
		if [ ! -f "$outputDir/decoded.ts" ]; then
			decodeList="$decodeList $outputDirRel"
		fi
		if [ ! -f "$outputDir/parsed.ts" ]; then
			parseList="$parseList $outputDirRel"
		fi
		reportList="$reportList $outputDirRel"

		progress_next "$outputDirRel"

	done < $optionsFile
	rm -f $optionsFile
	progress_end

	local self
	relative_path "$0"; self=$REPLY # just to make output look nicely

	#
	# Encoding
	#
	progress_begin "[2/5] Encoding..." "$encodeList"
	if [ -n "$encodeList" ]; then
		for outputDirRel in $encodeList; do
			echo "$self --ncpu $NCPU -- encode_single_file \"$outputDirRel\"" >> $TESTPLAN
		done
		"$dirScript/rpte2.sh" $TESTPLAN -p tmp -j $NCPU
	fi
	progress_end

	#
	# Decoding
	#
	NCPU=-1 # use (all+1) cores for decoding
	progress_begin "[3/5] Decoding..." "$decodeList"
	if [ -n "$decodeList" ]; then
		for outputDirRel in $decodeList; do
			echo "$self -- decode_single_file \"$outputDirRel\"" >> $TESTPLAN
		done
		"$dirScript/rpte2.sh" $TESTPLAN -p tmp -j $NCPU
	fi
	progress_end

	#
	# Parsing
	#
	NCPU=-16 # use (all + 16) cores
	progress_begin "[4/5] Parsing..." "$parseList"
	if [ -n "$parseList" ]; then
		for outputDirRel in $parseList; do
			echo "$self -- parse_single_file \"$outputDirRel\"" >> $TESTPLAN
		done
		"$dirScript/rpte2.sh" $TESTPLAN -p tmp -j $NCPU
	fi
	progress_end

	#
	# Reporting
	#
	progress_begin "[5/5] Reporting..."	"$reportList"
	if [ -z "$hide_banner" ]; then
		readonly timestamp=$(date "+%Y.%m.%d-%H.%M.%S")
		echo "$timestamp" >> $REPORT
		echo "$timestamp" >> $REPORT_KW

		output_legend
		output_header
	fi
	for outputDirRel in $reportList; do
		progress_next "$outputDirRel"
		report_single_file "$outputDirRel"
	done
	progress_end

	local duration=$(( SECONDS - startSec ))
	duration=$(date +%H:%M:%S -u -d @${duration})
	print_console "$duration >>>> $REPORT\n"
}

vectors_verify()
{
	local VECTORS="$*" vec= removeList=

	for vec in $VECTORS; do
		if ! [ -f "$vec" ]; then
			echo "warning: can't find vector. Remove '$vec' from a list."
			removeList="$removeList $vec"
			continue
		fi
	done

	for vec in $removeList; do
		VECTORS=$(echo "$VECTORS" | sed "s/$vec//")
	done

	local VECTORS_ABS=
	for vec in $VECTORS; do
		VECTORS_ABS="$VECTORS_ABS $(realpath "$vec")"
	done

	REPLY=$VECTORS_ABS
}

prepare_optionsFile()
{
	local optionsFile=$1; shift

	local prm= src= codecId= preset= infoTmpFile=$(mktemp)
	for prm in $PRMS; do
	for src in $VECTORS; do
	for codecId in $CODECS; do
	for preset in $PRESETS; do
		local qp=- bitrate=-
		if [ $prm -lt 60 ]; then
			qp=$prm
		else
			bitrate=$prm
		fi
		[ $preset == '-' ] && { codec_default_preset "$codecId"; preset=$REPLY; }
		local srcRes= srcFps= srcNumFr=
		detect_resolution_string "$src"; srcRes=$REPLY
		detect_framerate_string "$src"; srcFps=$REPLY
		detect_frame_num "$src" "$srcRes"; srcNumFr=$REPLY

		local args="--res "$srcRes" --fps $srcFps --threads $THREADS"
		[ $bitrate == '-' ] || args="$args --bitrate $bitrate"
		[ $qp == '-' ]     || args="$args --qp $qp"
		[ $preset == '-' ] || args="$args --preset $preset"

		local encExe= encExeHash= encCmdArgs= encCmdHash=
		codec_exe $codecId; encExe=$REPLY
		codec_hash $codecId; encExeHash=$REPLY
		codec_cmdArgs $codecId $args; encCmdArgs=$REPLY

		local SRC=${src//\\/}; SRC=${SRC##*[/\\]} # basename only
		local ext=h265; [ $codecId == h264demo ] && ext=h264
		local dst="$SRC.$ext"

		local info="src:$src codecId:$codecId srcRes:$srcRes srcFps:$srcFps srcNumFr:$srcNumFr"
		info="$info QP:$qp BR:$bitrate PRESET:$preset TH:$THREADS SRC:$SRC dst:$dst"
		info="$info encExe:$encExe encExeHash:$encExeHash encCmdArgs:$encCmdArgs"
		printf '%s\n' "$info"
	done
	done
	done
	done > $infoTmpFile

	local hashTmpFile=$(mktemp)
	while read data; do
		local encCmdArgs SRC
		dict_getValueEOL "$data" encCmdArgs; encCmdArgs=$REPLY
		dict_getValue "$data" SRC; SRC=$REPLY
		local args=${encCmdArgs// /}   # remove all whitespaces
		echo "$SRC $args"
	done < $infoTmpFile | python "$(ospath "$dirScript")/md5sum.py" | tr -d $'\r' > $hashTmpFile

	local data encCmdHash
	while IFS= read -u3 -r encCmdHash && IFS= read -u4 -r data; do 
  		printf 'encCmdHash:%s %s\n' "$encCmdHash" "$data"
	done 3<$hashTmpFile 4<$infoTmpFile > $optionsFile
	rm $infoTmpFile $hashTmpFile
}

PERF_ID=
start_cpu_monitor()
{
	local codecId=$1; shift
	local cpuLog=$1; shift

	local encoderExe=
	case $codecId in
		ashevc) 	encoderExe=$ashevcEncoderExe;;
		x265) 		encoderExe=$x265EncoderExe;;
		kvazaar) 	encoderExe=$kvazaarEncoderExe;;
		kingsoft) 	encoderExe=$kingsoftEncoderExe;;
		intel*)		encoderExe=$intelEncoderExe;;
		h265demo)	encoderExe=$h265EncDemoExe;;
		h264demo)	encoderExe=$HW264_Encoder_DemoExe;;
		*) echo "unknown codec($LINENO): $codecId" >&2 && return 1 ;;
	esac

	local name=$(basename "$encoderExe"); name=${name%.*}
	typeperf '\Process('$name')\% Processor Time' &
	PERF_ID=$!
}
stop_cpu_monitor()
{
	[ -z "$PERF_ID" ] && return 0
	{ kill -s INT $PERF_ID && wait $PERF_ID; } || true 
	PERF_ID=
}

PROGRESS_SEC=
PROGRESS_HDR=
PROGRESS_INFO=
PROGRESS_CNT_TOT=0
PROGRESS_CNT=0
progress_begin()
{
	local name=$1; shift
	local str=
	PROGRESS_SEC=$SECONDS
	PROGRESS_HDR=
	PROGRESS_INFO=
	PROGRESS_CNT_TOT=1
	PROGRESS_CNT=0
	rm -f $TESTPLAN

	for str; do
		list_size "$1"; PROGRESS_CNT_TOT=$(( PROGRESS_CNT_TOT * REPLY))
		shift
	done
	print_console "$name\n"

	if [ $PROGRESS_CNT_TOT == 0 ]; then
		print_console "No tasks to execute\n\n"
	else
		printf 	-v str "%8s %4s %-8s %11s %5s %2s %6s" "Time" $PROGRESS_CNT_TOT codecId resolution '#frm' QP BR 
		printf 	-v str "%s %9s %2s %-16s %-8s %s" "$str" PRESET TH CMD-HASH ENC-HASH SRC
		PROGRESS_HDR=$str
	fi
}
progress_next()
{
	local outputDirRel=$1; shift
	local outputDir="$DIR_OUT/$outputDirRel" info=

	info=$(cat $outputDir/info.kw)

	if [ -n "$PROGRESS_HDR" ]; then
		print_console "$PROGRESS_HDR\n"
		PROGRESS_HDR=
	fi

	PROGRESS_CNT=$(( PROGRESS_CNT + 1 ))

	local codecId= srcRes= srcFps= srcNumFr= QP= BR= PRESET= TH= SRC= HASH= ENC=
	dict_getValue "$info" codecId  ; codecId=$REPLY
	dict_getValue "$info" srcRes   ; srcRes=$REPLY
	dict_getValue "$info" srcFps   ; srcFps=$REPLY
	dict_getValue "$info" srcNumFr ; srcNumFr=$REPLY
	dict_getValue "$info" QP       ; QP=$REPLY
	dict_getValue "$info" BR       ; BR=$REPLY
	dict_getValue "$info" PRESET   ; PRESET=$REPLY
	dict_getValue "$info" TH       ; TH=$REPLY
	dict_getValue "$info" SRC      ; SRC=$REPLY
	dict_getValue "$info" encCmdHash ; HASH=$REPLY ; HASH=${HASH::16}
	dict_getValue "$info" encExeHash ; ENC=$REPLY  ; ENC=${ENC##*_}

	local str=
	printf 	-v str "%4s %-8s %11s %5s %2s %6s" 	"$PROGRESS_CNT" "$codecId" "${srcRes}@${srcFps}" "$srcNumFr" "$QP" "$BR"
	printf 	-v str "%s %9s %2s %-16s %-8s %s"    "$str" "$PRESET" "$TH" "$HASH" "$ENC" "$SRC"
	PROGRESS_INFO=$str # backup

	local duration=$(( SECONDS - PROGRESS_SEC ))
	duration=$(date +%H:%M:%S -u -d @${duration})

	print_console "$duration $PROGRESS_INFO\r"
}
progress_end()
{
	[ $PROGRESS_CNT == 0 ] && return

	local duration=$(( SECONDS - PROGRESS_SEC ))
	duration=$(date +%H:%M:%S -u -d @${duration})

	print_console "$duration $PROGRESS_INFO\n"

	PROGRESS_CNT_TOT=0
}

output_header()
{
	local str=
	printf 	-v str    "%6s %8s %5s %5s"                extFPS intFPS cpu% kbps
	printf 	-v str "%s %3s %7s %6s %4s"         "$str" '#I' avg-I avg-P peak 
	printf 	-v str "%s %6s %6s %6s %6s"         "$str" gPSNR psnr-I psnr-P gSSIM
	printf 	-v str "%s %-8s %11s %5s %2s %6s"	"$str" codecId resolution '#frm' QP BR 
	printf 	-v str "%s %9s %2s %-16s %-8s %s" 	"$str" PRESET TH CMD-HASH ENC-HASH SRC

#	print_console "$str\n"

	echo "$str" >> "$REPORT"
}
output_legend()
{
	local str=$(cat <<-'EOT'
		extFPS     - Estimated FPS: numFrames/encoding_time_sec		
		intFPS     - FPS counter reported by codec
		cpu%       - CPU load (100% <=> 1 core). Might be zero if encoding takes less than 1 sec
		kbps       - Actual bitrate: filesize/content_len_sec
		#I         - Number of INTRA frames
		avg-I      - Average INTRA frame size in bytes
		avg-P      - Average P-frame size in bytes
		peak       - Peak factor: avg-I/avg-P
		gPSNR      - Global PSNR. Follows x265 notation: (6*avgPsnrY + avgPsnrU + avgPsnrV)/8
		psnr-I     - Global PSNR. I-frames only
		psnr-P     - Global PSNR. P-frames only
		gSSIM      - Global SSIM in dB: -10*log10(1-ssim)
		QP         - QP value for fixed QP mode
		BR         - Target bitrate.
		TH         - Threads number.
	EOT
	)

#	echo "$str" > /dev/tty
}
output_report()
{
	local dict="$*"

	echo "$dict" >> $REPORT_KW

	local extFPS= intFPS= cpu= kbps= numI= avgI= avgP= peak= gPSNR= psnrI= psnrP= gSSIM=
	local codecId= srcRes= srcFps= numFr= QP= BR= PRESET= TH= SRC= HASH= ENC=

	dict_getValue "$dict" extFPS  ; extFPS=$REPLY
	dict_getValue "$dict" intFPS  ; intFPS=$REPLY
	dict_getValue "$dict" cpu     ; cpu=$REPLY
	dict_getValue "$dict" kbps    ; kbps=$REPLY
	dict_getValue "$dict" numI    ; numI=$REPLY
	dict_getValue "$dict" avgI    ; avgI=$REPLY
	dict_getValue "$dict" avgP    ; avgP=$REPLY
	dict_getValue "$dict" peak    ; peak=$REPLY
	dict_getValue "$dict" gPSNR   ; gPSNR=$REPLY
	dict_getValue "$dict" psnrI   ; psnrI=$REPLY
	dict_getValue "$dict" psnrP   ; psnrP=$REPLY
	dict_getValue "$dict" gSSIM   ; gSSIM=$REPLY
	dict_getValue "$dict" codecId ; codecId=$REPLY
	dict_getValue "$dict" srcRes  ; srcRes=$REPLY
	dict_getValue "$dict" srcFps  ; srcFps=$REPLY
	dict_getValue "$dict" srcNumFr; srcNumFr=$REPLY
	dict_getValue "$dict" QP      ; QP=$REPLY
	dict_getValue "$dict" BR      ; BR=$REPLY
	dict_getValue "$dict" PRESET  ; PRESET=$REPLY
	dict_getValue "$dict" TH      ; TH=$REPLY
	dict_getValue "$dict" SRC     ; SRC=$REPLY
	dict_getValue "$dict" encCmdHash; HASH=$REPLY; HASH=${HASH::16}
	dict_getValue "$dict" encExeHash; ENC=$REPLY ; ENC=${ENC##*_}

	local str=
	printf 	-v str    "%6s %8.2f %5s %5.0f"            "$extFPS" "$intFPS" "$cpu" "$kbps"
	printf 	-v str "%s %3d %7.0f %6.0f %4.1f"   "$str" "$numI" "$avgI" "$avgP" "$peak"
	printf 	-v str "%s %6.2f %6.2f %6.2f %6.3f" "$str" "$gPSNR" "$psnrI" "$psnrP" "$gSSIM"
	printf 	-v str "%s %-8s %11s %5d %2s %6s"	"$str" "$codecId" "${srcRes}@${srcFps}" "$srcNumFr" "$QP" "$BR"
	printf 	-v str "%s %9s %2s %-16s %-8s %s" 	"$str" "$PRESET" "$TH" "$HASH" "$ENC" "$SRC"

#	print_console "$str\n"
	echo "$str" >> $REPORT
}

report_single_file()
{
	local outputDirRel=$1; shift
	local outputDir="$DIR_OUT/$outputDirRel"

	local info= report=
	info=$(cat "$outputDir/info.kw")
	report=$(cat "$outputDir/report.kw")		

	output_report "$info $report"
}

encode_single_file()
{
	local outputDirRel=$1; shift
	local outputDir="$DIR_OUT/$outputDirRel"
	pushd "$outputDir"

	local info= codecId= src= dst= srcNumFr=
	info=$(cat info.kw)
	dict_getValue "$info" codecId; codecId=$REPLY
	dict_getValue "$info" srcNumFr; srcNumFr=$REPLY
	dict_getValue "$info" src; src=$REPLY
	dict_getValue "$info" dst; dst=$REPLY

	local cmd=
	cmd=$(cat cmd)

	local stdoutLog=stdout.log
	local cpuLog=cpu.log
	local fpsLog=fps.log

	local do_cpu_monitor=true

	# Do not estimate execution time if
	# 	- running in parallel
	#	- under WSL (does not see typeperf )
	# TODO: posix compatible monitor
	if [ $NCPU -ne 1 -o -n "${WSL_DISTRO_NAME:-}" ]; then
		do_cpu_monitor=false
	fi

	if $do_cpu_monitor; then
		# Start CPU monitor
		trap 'stop_cpu_monitor 1>/dev/null 2>&1' EXIT
		start_cpu_monitor "$codecId" "$cpuLog" > $cpuLog
	fi

	# Encode
	local consumedSec=$(date +%s%3N) # seconds*1000
	if ! { echo "yes" | $cmd; } 1>>$stdoutLog 2>&1 || [ ! -f "$dst" ]; then
		echo "" # newline if stderr==tty
		cat "$stdoutLog" >&2
		error_exit "encoding error, see logs above"
	fi
	consumedSec=$(( $(date +%s%3N) - consumedSec ))

	if $do_cpu_monitor; then
		# Stop CPU monitor
		stop_cpu_monitor
		trap -- EXIT

		local fps=0
		[ $consumedSec != 0 ] && fps=$(( 1000*srcNumFr/consumedSec ))
		echo "$fps" > $fpsLog
	fi

	date "+%Y.%m.%d-%H.%M.%S" > encoded.ts

	popd
}

decode_single_file()
{
	local outputDirRel=$1; shift
	local outputDir="$DIR_OUT/$outputDirRel"
	pushd "$outputDir"

	local info= src= dst=
	info=$(cat info.kw)
	dict_getValue "$info" src; src=$(ospath "$REPLY")
	dict_getValue "$info" dst; dst=$REPLY

	local recon=$(basename "$dst").yuv
	local kbpsLog=kbps.log
	local infoLog=info.log
	local ssimLog=ssim.log
	local psnrLog=psnr.log
	local frameLog=frame.log
	local summaryLog=summary.log

	local srcRes= srcFps= srcNumFr=
	dict_getValue "$info" srcRes; srcRes=$REPLY
	dict_getValue "$info" srcFps; srcFps=$REPLY
	dict_getValue "$info" srcNumFr; srcNumFr=$REPLY

	$ffmpegExe -y -loglevel error -i "$dst" "$recon"
	$ffprobeExe -v error -show_frames -i "$dst" | tr -d $'\r' > $infoLog

	local sizeInBytes= kbps=
	sizeInBytes=$(stat -c %s "$dst")
	kbps=$(awk "BEGIN { print 8 * $sizeInBytes / ($srcNumFr/$srcFps) / 1000 }")
	echo "$kbps" > $kbpsLog

	# ffmpeg does not accept filename in C:/... format as a filter option
	if ! log=$($ffmpegExe -hide_banner -s $srcRes -i "$src" -s $srcRes -i "$recon" -lavfi "ssim=$ssimLog;[0:v][1:v]psnr=$psnrLog" -f null - ); then
		echo "$log" && return 1
	fi
	rm -f "$recon"

	local numI=0 numP=0 sizeI=0 sizeP=0
	{
		local type= size= cnt=0
		while read -r; do
			case $REPLY in
				'[FRAME]')
					type=
					size=
					cnt=$(( cnt + 1 ))
				;;
				'[/FRAME]')
					[ $type == I ] && numI=$(( numI + 1 )) && sizeI=$(( sizeI + size ))
					[ $type == P ] && numP=$(( numP + 1 )) && sizeP=$(( sizeP + size ))
					echo "n:$cnt type:$type size:$size"
				;;
			esac
			case $REPLY in
				pict_type=I) type=I;;
				pict_type=P) type=P;;
			esac
			case $REPLY in pkt_size=*) size=${REPLY#pkt_size=}; esac
			# echo $v
		done < $infoLog
	} > $frameLog

	paste "$frameLog" "$psnrLog" "$ssimLog" | tr -d $'\r' > $summaryLog

	date "+%Y.%m.%d-%H.%M.%S" > decoded.ts

	popd
}

parse_single_file()
{
	local outputDirRel=$1; shift
	local outputDir="$DIR_OUT/$outputDirRel"
	pushd "$outputDir"

	local info= codecId=
	info=$(cat info.kw)
	dict_getValue "$info" codecId; codecId=$REPLY

	local stdoutLog=stdout.log
	local kbpsLog=kbps.log
	local cpuLog=cpu.log
	local fpsLog=fps.log
	local summaryLog=summary.log

	local cpuAvg=- extFPS=- intFPS= framestat=
	if [ -f "$cpuLog" ]; then # may not exist
		cpuAvg=$(parse_cpuLog "$cpuLog")
		printf -v cpuAvg "%.0f" "$cpuAvg"
	fi
	if [ -f "$fpsLog" ]; then # may not exist
		extFPS=$(cat "$fpsLog")
	fi
	intFPS=$(parse_stdoutLog "$codecId" "$stdoutLog")
	framestat=$(parse_framestat "$kbpsLog" "$summaryLog")

	local dict="extFPS:$extFPS intFPS:$intFPS cpu:$cpuAvg $framestat"
	echo "$dict" > report.kw

	date "+%Y.%m.%d-%H.%M.%S" > parsed.ts

	popd
}

parse_framestat()
{
	local kbpsLog=$1; shift
	local summaryLog=$1; shift

	countTotal() { 
		awk '{ cnt +=  1 } END { print cnt }'
	}
	countSum() { 
		awk '{ sum += $1 } END { print sum }'
	}
	countAverage() { 
		awk '{ sum += $1; cnt++ } END { print cnt !=0 ? sum / cnt : 0 }'
	}
	countMSE() { # mse_y mse_u mse_v -> mse
		awk '{ print ( $1 + $2/4 + $3/4 ) / 1.5 }'
	}
	countGlobalPSNR() { # psnr_y psnr_y psnr_v -> globalPSNR
		awk '{ print ( 6*$1 + $2 + $3 ) / 8 }'
	}

	local kbps=
	kbps=$(cat "$kbpsLog")

	local psnrI= psnrP= gPSNR=
	if [ 0 == 1 ]; then # Avg(FramePSNR)
		psnrI=$( grep -i 'type:I' "$summaryLog" | sed 's/.* psnr_avg:\([^ ]*\).*/\1/' | countAverage )
		psnrP=$( grep -i 'type:P' "$summaryLog" | sed 's/.* psnr_avg:\([^ ]*\).*/\1/' | countAverage )
	else                # GlobalPSNR( Avg(Y), Avg(U), Avg(V) ) <= x265
		local psnr_y=$( grep -i 'type:I' "$summaryLog" | sed 's/.* psnr_y:\([^ ]*\).*/\1/' | countAverage )
		local psnr_u=$( grep -i 'type:I' "$summaryLog" | sed 's/.* psnr_u:\([^ ]*\).*/\1/' | countAverage )
		local psnr_v=$( grep -i 'type:I' "$summaryLog" | sed 's/.* psnr_v:\([^ ]*\).*/\1/' | countAverage )
		psnrI=$(echo "$psnr_y" "$psnr_u" "$psnr_v" | countGlobalPSNR)

		local psnr_y=$( grep -i 'type:P' "$summaryLog" | sed 's/.* psnr_y:\([^ ]*\).*/\1/' | countAverage )
		local psnr_u=$( grep -i 'type:P' "$summaryLog" | sed 's/.* psnr_u:\([^ ]*\).*/\1/' | countAverage )
		local psnr_v=$( grep -i 'type:P' "$summaryLog" | sed 's/.* psnr_v:\([^ ]*\).*/\1/' | countAverage )
		psnrP=$(echo "$psnr_y" "$psnr_u" "$psnr_v" | countGlobalPSNR)
	fi
	{
		local psnr_y=$( cat "$summaryLog" | sed 's/.* psnr_y:\([^ ]*\).*/\1/' | countAverage )
		local psnr_u=$( cat "$summaryLog" | sed 's/.* psnr_u:\([^ ]*\).*/\1/' | countAverage )
		local psnr_v=$( cat "$summaryLog" | sed 's/.* psnr_v:\([^ ]*\).*/\1/' | countAverage )
		gPSNR=$(echo "$psnr_y" "$psnr_u" "$psnr_v" | countGlobalPSNR)
	}

	local ssimI= ssimP= gSSIM=
	if [ 0 == 1 ]; then # Full
		ssimI=$( grep -i 'type:I' "$summaryLog" | sed 's/.* All:\([^ ]*\).*/\1/' | countAverage )
		ssimP=$( grep -i 'type:P' "$summaryLog" | sed 's/.* All:\([^ ]*\).*/\1/' | countAverage )
		gSSIM=$(              cat "$summaryLog" | sed 's/.* All:\([^ ]*\).*/\1/' | countAverage )
	else                # Luma <= x265 reports only Y-SSIM
		ssimI=$( grep -i 'type:I' "$summaryLog" | sed 's/.* Y:\([^ ]*\).*/\1/' | countAverage )
		ssimP=$( grep -i 'type:P' "$summaryLog" | sed 's/.* Y:\([^ ]*\).*/\1/' | countAverage )
		gSSIM=$(              cat "$summaryLog" | sed 's/.* Y:\([^ ]*\).*/\1/' | countAverage )
	fi

	local numI=$(  grep -i 'type:I' "$summaryLog" | countTotal )
	local sizeI=$( grep -i 'type:I' "$summaryLog" | sed 's/.* size:\([^ ]*\).*/\1/' | countSum )
	local avgI=$(  grep -i 'type:I' "$summaryLog" | sed 's/.* size:\([^ ]*\).*/\1/' | countAverage )
	local numP=$(  grep -i 'type:P' "$summaryLog" | countTotal )
	local sizeP=$( grep -i 'type:P' "$summaryLog" | sed 's/.* size:\([^ ]*\).*/\1/' | countSum)
	local avgP=$(  grep -i 'type:P' "$summaryLog" | sed 's/.* size:\([^ ]*\).*/\1/' | countAverage )
	local peakFac=$(echo "$avgI $avgP" | awk '{ fac = $2 != 0 ? $1 / $2 : 0; print fac; }' )

	x265_ssim2dB() {
		awk -v ssim=$1 'BEGIN { 
			print (1 - ssim) <= 0.0000000001 ? 100 : -10*log(1 - ssim)/log(10)
		}'
	}
	local gSSIM_db=$(x265_ssim2dB "$gSSIM")
	local gSSIM_en=$gSSIM
	gSSIM=$gSSIM_db # report in dB, write to kw-report in linear and dB scale
 
	echo 	"kbps:$kbps "\
			"numI:$numI numP:$numP sizeI:$sizeI sizeP:$sizeP "\
			"avgI:$avgI avgP:$avgP peak:$peakFac "\
			"psnrI:$psnrI psnrP:$psnrP gPSNR:$gPSNR ssimI:$ssimI ssimP:$ssimP gSSIM:$gSSIM "\
			"gSSIM_db:$gSSIM_db gSSIM_en:$gSSIM_en"
}

parse_cpuLog()
{
	local log=$1; shift
: <<'FORMAT'
                                                                             < skip (first line is empty)
"(PDH-CSV 4.0)","\\DESKTOP-7TTKF98\Process(sample_encode)\% Processor Time"  < skip
"04/02/2020 07:37:58.154","388.873717"                                       < count average
"04/02/2020 07:37:59.205","390.385101"
FORMAT
	cat "$log" | tail -n +3 | cut -d, -f 2 | tr -d \" | 
			awk '{ if ( $1 != "" && $1 > 0 ) { sum += $1; cnt++; } } END { print cnt !=0 ? sum / cnt : 0 }'
}

parse_stdoutLog()
{
	local codecId=$1; shift
	local log=$1; shift
	local fps= snr=
	case $codecId in
		ashevc)
			fps=$(cat "$log" | grep ' fps)' | tr -s ' ' | cut -d' ' -f 6); fps=${fps#(}
		;;
		x265)
			fps=$(cat "$log" | grep ' fps)' | tr -s ' ' | cut -d' ' -f 6); fps=${fps#(}
		;;
		kvazaar)
			fps=$(cat "$log" | grep ' FPS:' | tr -s ' ' | cut -d' ' -f 3)
		;;
		kingsoft)
			fps=$(cat "$log" | grep 'test time: ' | tr -s ' ' | cut -d' ' -f 8)
			#fps=$(cat "$log" | grep 'pure encoding time:' | head -n 1 | tr -s ' ' | cut -d' ' -f 8)
		;;
		intel_*)
			fps=$(cat "$log" | grep 'Encoding fps:' | tr -s ' ' | cut -d' ' -f 3)
		;;
		h265demo)
			fps=$(cat "$log" | grep 'TotalFps:' | tr -s ' ' | cut -d' ' -f 5)
		;;
		h264demo)
			fps=$(cat "$log" | grep 'Tests completed' | tr -s ' ' | cut -d' ' -f 1)
			snr=$(cat "$log" | grep 'Tests completed' | tr -s ' ' | cut -d' ' -f 5)
		;;
		*) error_exit "unknown encoder: $codecId";;
	esac

	echo "$fps"
}

entrypoint "$@"

# https://filmora.wondershare.com/video-editing-tips/what-is-video-bitrate.html
# Quality   ResolutionVideo   Bitrate  [ Open Broadcasting Software ]
# LOW        480x270           400
# Medium     640x360           800-1200
# High       960x540/854x480  1200-1500
# HD        1280x720          1500-4000
# HD1080    1920x1080	      4000-8000
# 4K        3840x2160         8000-14000

# https://bitmovin.com/video-bitrate-streaming-hls-dash/  H.264
# Resolution	FPS	Bitrate   Bits/Pixel
#  426x240       24      250   400   700 0.10 0.17 0.29
#  640x360       24      500   800  1400 0.09 0.15 0.26
#  854x480       24      750  1200  2100 0.08 0.12 0.22
# 1280x720       24     1500  2400  4200 0.07 0.11 0.19
# 1920x1080      24     3000  4800  8400 0.06 0.10 0.17
# 4096x2160      24    10000 16000 28000 0.05 0.08 0.14

# https://developers.google.com/media/vp9/bitrate-modes
