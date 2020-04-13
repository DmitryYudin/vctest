set -eu -o pipefail

dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
. "$dirScript/utility_functions.sh"

readonly dirScript=$(cygpath -m "$dirScript")

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

readonly ashevcEncoderExe=$dirScript/../'bin\ashevc\cli_ashevc.exe'
readonly x265EncoderExe=$dirScript/../'bin\x265\x265.exe'
readonly kvazaarEncoderExe=$dirScript/../'bin\kvazaar\kvazaar.exe'
readonly kingsoftEncoderExe=$dirScript/../'bin\kingsoft/AppEncoder_x64.exe'
readonly intelEncoderExe=$dirScript/../'bin\intel\sample_encode.exe' # can't run HW.
readonly h265EncDemoExe=$dirScript/../'bin\hw265\h265EncDemo.exe'
readonly HW264_Encoder_DemoExe=$dirScript/../'bin\hme264\HW264_Encoder_Demo.exe'
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
	       --preset   Codec-specific list of 'preset' options (default: marked by *):
	                  ashevc:   *1 2 3 4 5 6
	                  x265:     *ultrafast  superfast veryfast  faster fast medium slow slower veryslow placebo
	                  kvazaar:  *ultrafast  superfast veryfast  faster fast medium slow slower veryslow placebo
	                  kingsoft:  ultrafast *superfast veryfast         fast medium slow        veryslow placebo
	                  intel_sw:                       veryfast *faster fast medium slow slower veryslow
	                  intel_hw:                       veryfast  faster fast medium slow slower veryslow
	                  h265demo: 6 *5 4 3 2 1
	                  h264demo: N/A
	       --hide     Do not print legend and header
	Note, 'prms' values less than 60 considered as QP.
	EOF
}

entrypoint()
{
	local cmd_vec= cmd_report= cmd_codecs= cmd_threads= cmd_prms= cmd_presets= cmd_dirOut=
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
			   --hide)		hide_banner=1; nargs=1;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift $nargs
	done
	[ -n "$cmd_dirOut" ] && DIR_OUT=$cmd_dirOut
	[ -n "$cmd_report" ] && REPORT=$cmd_report && REPORT_KW=${REPORT%.*}.kw
	[ -n "$cmd_vec" ] && VECTORS=${cmd_vec# }
	[ -n "$cmd_codecs" ] && CODECS=$cmd_codecs
	[ -n "$cmd_threads" ] && THREADS=$cmd_threads
	[ -n "$cmd_prms" ] && PRMS=$cmd_prms
	[ -n "$cmd_presets" ] && PRESETS=$cmd_presets

	mkdir -p "$DIR_OUT" "$(dirname $REPORT)"

	# Make sure we can run intel hardware encoder
	if echo "$CODECS" | grep -i 'intel_hw' > /dev/null; then
		cmd=$(cmd_intel_hw -i "$0" -o "$DIR_OUT/out.tmp" --res "64x64" --fps 30)
		if ! $cmd 1>/dev/null 2>&1; then
			echo "warning: intel_hw encoder is not available" >&2;
			CODECS=$(echo "$CODECS" | sed 's/intel_hw//')
		fi
		rm -f "$DIR_OUT/out.tmp"
	fi

	readonly timestamp=$(date "+%Y.%m.%d-%H.%M.%S")
	if [ -z "$hide_banner" ]; then
		echo "$timestamp" >> $REPORT
		echo "$timestamp" >> $REPORT_KW

		output_legend
		output_header
	fi

	local prm= src= codecId=
	for prm in $PRMS; do
	for src in $VECTORS; do
	for codecId in $CODECS; do
	for preset in ${PRESETS:--}; do
		local qp=- bitrate=-
		if [ $prm -lt 60 ]; then
			qp=$prm
		else
			bitrate=$prm
		fi
		[ $preset == '-' ] && preset=$(codec_default_preset "$codecId")

		local srcRes=$(detect_resolution_string "$src")
		[ -z "$srcRes" ] && error_exit "can't detect resolution for $src"
		local srcFps=$(detect_framerate_string "$src")
		local width=${srcRes%%x*}
		local height=${srcRes##*x}

		local srcNumFr=$(detect_frame_num "$src" "$srcRes")
		[ -z "$srcNumFr" ] && error_exit "can't detect number of frames for $src"

		local ext=h265; [ $codecId == h264demo ] && ext=h264

		local args="--res "$srcRes" --fps $srcFps --threads $THREADS"
		[ $bitrate == '-' ] || args="$args --bitrate $bitrate"
		[ $qp == '-' ]     || args="$args --qp $qp"
		[ $preset == '-' ] || args="$args --preset $preset"

		local encExe= encExeHash= encCmdArgs= encCmdHash=
		encExe=$(codec_exe $codecId)
		encExeHash=$(codec_hash $codecId)
		encCmdArgs=$(codec_cmdArgs $codecId $args)
		encCmdHash=$(codec_cmdHash "$src" $encCmdArgs)
		local outputDir="$DIR_OUT/$encExeHash/$encCmdHash"
		local dst="$outputDir/$(basename "$src").$ext"
		local stdoutLog="$outputDir/stdout.log"
		local cpuLog="$outputDir/cpu.log"
		local fpsLog="$outputDir/fps.log"

		local info="codecId:$codecId srcRes:${width}x${height} srcFps:$srcFps srcNumFr:$srcNumFr QP:$qp BR:$bitrate PRESET:$preset"
		info="$info TH:$THREADS SRC:$(basename $src) encCmdHash:$encCmdHash"
		output_info "$info"

		if [ ! -f "$outputDir/encoded.ts" ]; then

			rm -rf "$(dirname "$dst")/"
			mkdir -p "$(dirname "$dst")"

			local encCmdSrc= encCmdDst=
			encCmdSrc=$(codec_cmdSrc $codecId "$src")
			encCmdDst=$(codec_cmdDst $codecId "$dst")
			{
				echo "$codecId"
				echo "$encCmdArgs"
				echo "$encCmdSrc"
				echo "$encCmdDst"
			} > $stdoutLog
			local cmd="$encExe $encCmdArgs $encCmdSrc $encCmdDst"

			# Start CPU monitor
			trap 'stop_cpu_monitor 1>/dev/null 2>&1' EXIT
			start_cpu_monitor "$codecId" "$cpuLog" > $cpuLog

			# Encode
			local consumedSec=$(date +%s%3N) # seconds*1000
			if ! { echo "yes" | $cmd; } 1>>$stdoutLog 2>&1 || [ ! -f "$dst" ]; then
				echo "" # newline if stderr==tty
				cat "$stdoutLog" >&2
				error_exit "encoding error, see logs above"
			fi
			consumedSec=$(( $(date +%s%3N) - consumedSec ))

			# Stop CPU monitor
			stop_cpu_monitor
			trap -- EXIT

			local fps=0
			[ $consumedSec != 0 ] && fps=$(( 1000*srcNumFr/consumedSec ))
			echo "$fps" > $fpsLog

			echo "$(date "+%Y.%m.%d-%H.%M.%S")" > $outputDir/encoded.ts
		fi

		if [ ! -f "$outputDir/decoded.ts" ]; then

            decode "$src" "$dst" "$outputDir"

			echo "$(date "+%Y.%m.%d-%H.%M.%S")" > $outputDir/decoded.ts
		fi

		local cpuAvg=$(parse_cpuLog "$cpuLog")
		local extFPS=$(cat "$fpsLog")
		local intFPS=$(parse_stdoutLog $stdoutLog)
		local kbps=$(parse_kbps "$dst" "$srcNumFr" "$srcFps")
		local framestat=$(parse_framestat "$outputDir")

		output_report "extFPS:$extFPS intFPS:$intFPS cpu:$cpuAvg kbps:$kbps $framestat $info"
	done
	done
	done
	done
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

	echo "$str" > /dev/tty
}

output_header()
{
	local str=
	printf 	-v str    "%6s %6s %5s %5s"                extFPS intFPS cpu% kbps
	printf 	-v str "%s %3s %7s %6s %4s"         "$str" '#I' avg-I avg-P peak 
	printf 	-v str "%s %6s %6s %6s %6s"         "$str" gPSNR psnr-I psnr-P gSSIM
	printf 	-v str "%s %-8s %11s %5s %2s %6s"	"$str" codecId resolution '#frm' QP BR 
	printf 	-v str "%s %9s %2s %-16s %s" 		"$str" PRESET TH HASH SRC

	print_console "$str\n"

	echo "$str" >> "$REPORT"
}

output_info()
{
	local dict="$*"
	local codecId=$(dict_getValue "$dict" codecId)
	local srcRes=$(dict_getValue "$dict" srcRes)
	local srcFps=$(dict_getValue "$dict" srcFps)
	local srcNumFr=$(dict_getValue "$dict" srcNumFr)
	local QP=$(dict_getValue "$dict" QP)
	local BR=$(dict_getValue "$dict" BR)
	local PRESET=$(dict_getValue "$dict" PRESET)
	local TH=$(dict_getValue "$dict" TH)
	local SRC=$(dict_getValue "$dict" SRC)
	local HASH=$(dict_getValue "$dict" encCmdHash)

	local str=
	printf 	-v str    "%6s %6s %5s %5s"                "" "" "" ""
	printf 	-v str "%s %3s %7s %6s %4s"         "$str" "" "" "" ""
	printf 	-v str "%s %6s %6s %6s %6s"         "$str" "" "" "" ""
	printf 	-v str "%s %-8s %11s %5s %2s %6s" 	"$str" "$codecId" "${srcRes}@${srcFps}" "$srcNumFr" "$QP" "$BR"
	printf 	-v str "%s %9s %2s %-16s %s"  		"$str" "$PRESET" "$TH" "${HASH::16}" "$SRC"

	print_console "$str\r"
}

output_report()
{
	local dict="$*"

	echo "$dict" >> $REPORT_KW

	local extFPS=$(dict_getValue "$dict" extFPS)
	local intFPS=$(dict_getValue "$dict" intFPS)
	local cpu=$(dict_getValue "$dict" cpu)
	local kbps=$(dict_getValue "$dict" kbps)
	local numI=$(dict_getValue "$dict" numI)
	local avgI=$(dict_getValue "$dict" avgI)
	local avgP=$(dict_getValue "$dict" avgP)
	local peak=$(dict_getValue "$dict" peak)
	local gPSNR=$(dict_getValue "$dict" gPSNR)
	local psnrI=$(dict_getValue "$dict" psnrI)
	local psnrP=$(dict_getValue "$dict" psnrP)
	local gSSIM=$(dict_getValue "$dict" gSSIM)
	local codecId=$(dict_getValue "$dict" codecId)
	local srcRes=$(dict_getValue "$dict" srcRes)
	local srcFps=$(dict_getValue "$dict" srcFps)
	local srcNumFr=$(dict_getValue "$dict" srcNumFr)
	local QP=$(dict_getValue "$dict" QP)
	local BR=$(dict_getValue "$dict" BR)
	local PRESET=$(dict_getValue "$dict" PRESET)
	local TH=$(dict_getValue "$dict" TH)
	local SRC=$(dict_getValue "$dict" SRC)
	local HASH=$(dict_getValue "$dict" encCmdHash)

	local str=
	printf 	-v str    "%6s %6.0f %5.0f %5.0f"          "$extFPS" "$intFPS" "$cpu" "$kbps"
	printf 	-v str "%s %3d %7.0f %6.0f %4.1f"   "$str" "$numI" "$avgI" "$avgP" "$peak"
	printf 	-v str "%s %6.2f %6.2f %6.2f %6.3f" "$str" "$gPSNR" "$psnrI" "$psnrP" "$gSSIM"
	printf 	-v str "%s %-8s %11s %5d %2s %6s"	"$str" "$codecId" "${srcRes}@${srcFps}" "$srcNumFr" "$QP" "$BR"
	printf 	-v str "%s %9s %2s %-16s %s" 		"$str" "$PRESET" "$TH" "${HASH::16}" "$SRC"

	print_console "$str\n"
	echo "$str" >> $REPORT
}

decode()
{
	local src=$1; shift
	local dst=$1; shift
	local outputDir=$1; shift

	local recon="$outputDir/$(basename "$dst").yuv"
	local infoLog="$outputDir/info.log"
	local ssimLog="$outputDir/ssim.log"
	local psnrLog="$outputDir/psnr.log"
	local frameLog="$outputDir/frame.log"
	local summaryLog="$outputDir/summary.log"

	local srcRes=$(detect_resolution_string "$src")

	$ffmpegExe -y -loglevel error -i "$dst" "$recon"        
	$ffprobeExe -v error -show_frames -i "$dst" | tr -d $'\r' > $infoLog
    			
	local ssimTmp=$(basename $ssimLog) # can't pass 'C:/...' to ffmpeg filter args, use temporary file
	{   # ignore output
		$ffmpegExe -hide_banner -s $srcRes -i "$src" -s $srcRes -i "$recon" -lavfi "ssim=stats_file=$ssimTmp" -f null - 2>&1 \
			| grep '\[Parsed_' | sed 's/.*SSIM //'
	} > /dev/null
	cat "$ssimTmp" | tr -d $'\r' > "$ssimLog" && rm "$ssimTmp"

	local psnrTmp=$(basename $psnrLog)
	{   # ignore output
		$ffmpegExe -hide_banner -s $srcRes -i "$src" -s $srcRes -i "$recon" -lavfi "psnr=stats_file=$psnrTmp" -f null - 2>&1 \
			| grep '\[Parsed_' | sed 's/.*PSNR //'
	} > /dev/null
	cat "$psnrTmp" | tr -d $'\r' > "$psnrLog" && rm "$psnrTmp"

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

	paste "$frameLog" "$psnrLog" "$ssimLog" > $summaryLog
}

parse_framestat()
{
	local outputDir=$1; shift
	local summaryLog="$outputDir/summary.log"

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
 
	echo 	"numI:$numI numP:$numP sizeI:$sizeI sizeP:$sizeP "\
			"avgI:$avgI avgP:$avgP peak:$peakFac "\
			"psnrI:$psnrI psnrP:$psnrP gPSNR:$gPSNR ssimI:$ssimI ssimP:$ssimP gSSIM:$gSSIM "\
			"gSSIM_db:$gSSIM_db gSSIM_en:$gSSIM_en"
}

parse_kbps()
{
	local compressed=$1 numFrames=$2; fps=$3
	local bytes=$(stat -c %s "$compressed")
	awk "BEGIN { print 8 * $bytes / ($numFrames/$fps) / 1000 }"
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
	local log=$1; shift
	local fps= snr=
	local codecId=$(cat "$log" | head -n 1);
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

codec_default_preset()
{
	local codecId=$1; shift
	local preset=

	case $codecId in
		ashevc) 	preset=1;;
		x265) 		preset=ultrafast;;
		kvazaar) 	preset=ultrafast;;
		kingsoft)	preset=superfast;;
		intel_*)	preset=faster;;
		h265demo)	preset=5;;
		h264demo)	preset=-;;
		*) error_exit "unknown encoder: $codecId";;
	esac

	echo "$preset"
}
codec_exe()
{
	local codecId=$1; shift
	local encoderExe=$(exe_${codecId})
	[ -f "$encoderExe" ] || error_exit "encoder does not exist '$encoderExe'"
	echo "$encoderExe"
}
codec_hash()
{
	local codecId=$1; encoderExe= hash=
	encoderExe=$(codec_exe $codecId)
	hash=$(md5sum ${encoderExe//\\//} | cut -d' ' -f 1 | base64)
	echo "${codecId}_${hash::8}"
}
codec_cmdArgs()
{
	local codecId=$1; shift
	cmd_${codecId} "$@"
}
codec_cmdHash()
{
	local src=$1; shift
	local args=$*; shift
	echo "$(basename "$src") $args" | md5sum | base64
}
codec_cmdSrc()
{
	local codecId=$1; shift
	local src=$1; shift
	src_${codecId} "$src"
}
codec_cmdDst()
{
	local codecId=$1; shift
	local dst=$1; shift
	dst_${codecId} "$dst"
}

exe_x265() { echo "$x265EncoderExe"; }
src_x265() { echo "--input $1"; }
dst_x265() { echo "--output $1"; }
cmd_x265()
{
	local args= threads=0
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args --input $2";;
			-o|--output) 	args="$args --output $2";;
			   --res) 		args="$args --input-res $2";;
			   --fps) 		args="$args --fps $2";;
			   --preset) 	args="$args --preset $2";; # ["ultrafast","superfast","veryfast","faster","fast","medium","slow","slower","veryslow","placebo"]
			   --qp)     	args="$args --qp $2";;
			   --bitrate)   args="$args --bitrate $2";;
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done

	args="$args --pools $threads"  # TODO
	args="$args --ref 1"           # Num reference frames
	args="$args --bframes 0"       # Disable B-frames
	args="$args --frame-threads 1" # Number of concurrently encoded frames. 
	args="$args --rc-lookahead 0"  # Number of frames for frame-type lookahead 
#	args="$args --tune psnr"       # Enable "--tune psnr" produce worse gPSNR for tears_of_steel_1728x720_24.webm.yuv@1M
	args="$args --psnr"
	args="$args --ssim"

	echo "$args"
}

exe_ashevc() { echo "$ashevcEncoderExe"; }
src_ashevc() { echo "--input $1"; }
dst_ashevc() { echo "--output $1"; }
cmd_ashevc()
{
	local args= threads=1 res= preset=5
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args --input $2";;
			-o|--output) 	args="$args --output $2";;
			   --res) 		res=$2;;
			   --fps) 		args="$args --fps $2";;
			   --preset) 	preset=$2;; # 1 ~ 6: 1 is fastest, 6 is slowest. default 5
			   --qp)     	args="$args --qp $2      --rc 12";; # rc=12: CQP
			   --bitrate)   args="$args --bitrate $2 --rc 8";;  # rc=8: ABR
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done
	local width=${res%%x*}
	local height=${res##*x}
	args="$args --width $width"
	args="$args --height $height"
	args="$args --preset $preset"   # Must be explicitly set

	args="$args --wpp-threads $threads" # 0: Process everything with main thread.
	args="$args --ref 1"           	# Num reference frames
	args="$args --bframes 0"		# Disable B-frames
	args="$args --lookaheadnum 0 --lookahead-threads 0"
	args="$args --frame-threads 1"	# Does it have the same meaning as for x265?
	args="$args --keyint 999999"	# Only first picture is intra.
	args="$args --psnr 1"
	args="$args --ssim 1"
	args=${args# *}
	args=${args// / }

	echo "$args"
}

exe_kvazaar() { echo "$kvazaarEncoderExe"; }
src_kvazaar() { echo "--input $1"; }
dst_kvazaar() { echo "--output $1"; }
cmd_kvazaar()
{
	local args= threads=0
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args --input $2";;
			-o|--output) 	args="$args --output $2";;
			   --res) 		args="$args --input-res $2";;
			   --fps) 		args="$args --input-fps $2";;
			   --preset) 	args="$args --preset $2";; # ["ultrafast","superfast","veryfast","faster","fast","medium","slow","slower","veryslow","placebo"]
			   --qp)     	args="$args --qp $2";;
			   --bitrate)   args="$args --bitrate $(( 1000 * $2 ))";;
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done

	args="$args --threads $threads" # 0: Process everything with main thread.
	args="$args --ref 1"           	# Num reference frames
	args="$args --no-bipred --gop 0" # Disable B-frames
	args="$args --owf 0" 			# Frame-level parallelism. Process N+1 frames at a time.
	args="$args --period 0"         # Only first picture is intra.

	echo "${args# *}"
}

exe_kingsoft() { echo "$kingsoftEncoderExe"; }
src_kingsoft() { echo "-i $1"; }
dst_kingsoft() { echo "-b $1"; }
cmd_kingsoft()
{
	local args= threads=1 res=
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args -i $2";;
			-o|--output) 	args="$args -b $2";;
			   --res) 		res=$2;;
			   --fps) 		args="$args -fr $2";;
			   --preset) 	args="$args -preset $2";; # ultrafast, superfast, veryfast, fast, medium, slow, veryslow, placebo
			   --qp)     	args="$args -qp $2 -qpmin $2 -qpmax $2";; # valid when RCType != 0, (maybe -fixqp ?)
			   --bitrate)   args="$args -br $2";;
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done
	local width=${res%%x*}
	local height=${res##*x}
	args="$args -wdt $width"
	args="$args -hgt $height"

	args="$args -threads $threads"
	args="$args -ref 1 -ref0 1"     # Num reference frames
	args="$args -lookahead 0"
	args="$args -bframes 0"			# Disable B-frames
	args="$args -iper -1"         	# Only first picture is intra.
#	args="$args -fpp 1" 			# TODO: enable frame level parallel

	echo "$args"
}

cmd_intel()
{
	local args= threads=1 res=
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args -i $2";;
			-o|--output) 	args="$args -o $2";;
			   --res) 		res=$2;;
			   --fps) 		args="$args -f $2";;
#			   --preset) 	args="$args -preset $2";; # default, dss, conference, gaming
			   --preset)	args="$args -u $2";; # usage: veryslow(quality), slower, slow, medium(balanced), fast, faster, veryfast(speed)
			   --qp)     	args="$args -cqp -qpi $2 -qpp $2";;
			   --bitrate)   args="$args -b $2";;
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done
	local width=${res%%x*}
	local height=${res##*x}
	args="$args -w $width"
	args="$args -h $height"

#	args="$args -threads $threads"  # Not available
	args="$args -x 1"     			# Num reference frames
	args="$args -gpb:off"			# Disable B-frames (Use regular P-frames instead of GPB aka low delay B-frames)
	args="$args -r 1"         	    # Disable B-frames (Distance between I- or P- key frames (1 means no B-frames))
	args="$args -nobref"            # Disable B-frames (Do not reference B-frames)
	args="$args -x 1"         		# Number of reference frames
#	args="$args -num_active_P 1"	# Number of maximum allowed references for P frames

	echo "h265 $args"
}

exe_intel_sw() { echo "$intelEncoderExe"; }
src_intel_sw() { echo "-i $1"; }
dst_intel_sw() { echo "-o $1"; }
cmd_intel_sw()
{
	echo "$(cmd_intel "$@") -sw"
}
exe_intel_hw() { echo "$intelEncoderExe"; }
src_intel_hw() { echo "-i $1"; }
dst_intel_hw() { echo "-o $1"; }
cmd_intel_hw() 
{
	echo "$(cmd_intel "$@") -hw"
}

exe_h265demo() { echo "$h265EncDemoExe"; }
src_h265demo() { echo "-i $1"; }
dst_h265demo() { echo "-b $1"; }
cmd_h265demo()
{
	local args= threads=1 res= fps= preset=6
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args -i $2";;
			-o|--output) 	args="$args -b $2";;
			   --res) 		res=$2;;
			   --fps) 		fps=$2;;
			   --preset) 	preset=$2;; # 0-7 or 1-7
#			   --preset)	args="$args -u $2";; # usage: veryslow(quality), slower, slow, medium(balanced), fast, faster, veryfast(speed)
			   --qp)     	args="$args -rc 2 -qp $2";;
			   --bitrate)   args="$args -rc 0 -br $2";;
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done
	local width=${res%%x*}
	local height=${res##*x}
	args="$args -w $width"
	args="$args -h $height"

#	args="$args -fr $(( inputFPS * 1000))"
	args="$args -WppThreadNum $threads"
	args="$args -FrmThreadNum 1"  # fixed
	local cfg=$(cat <<-END_OF_CFG	
		###########################################################################################
		# Encoder Open Param
		###########################################################################################
		InitQP = 37
		ChannelID = 0
		SourceWidth  = $width
		SourceHeight = $height
		ColorSpace  = 0         # 0: YUV420; 1; YUVJ420  
		Profile = 0             # 0: MAIN
		IntraPeriod = 1000		#
		FixedIntraPeriod = 0    # {0,1}
		Bframes = 0             #
		BframeRef = 1

		# RCMode = 0			# 0: ABR;  1: CRF 2:CQP (set from command line)

		BitRate = 2000
		FrameRateNum = $fps
		FrameRateDen = 1
		VfrInput = 0
		TimeBaseNum = 1
		TimeBaseDen = 25
		Pass = 0
		Crf = 23
		BitRatePAR = 1
		BitrateParCovStrength = 0
		Adaptive_IFrame = 0
		LookAheadThreads = 1
		EtoEDelayTime = 0
		DelayNum = 0
		Preset = $preset
		Tune = 0
		DebugLevel = 1
		PvcLevel = 0
		PvcMode = 0
		PvcStrenght = 0
		PSNREnable = 1

		FramesToBeEncoded = 99999  # Number of frames to be coded
		FixTimeSendYUV = 0 
		#ReconFile = rec.yuv		
		#ReconEnable = 1
	END_OF_CFG
	)
	local hash=$(echo "$cfg" | md5sum | base64)
	local _dirScript=$(cygpath -m "$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )")
	local pathCfg="$_dirScript/persistent/h265demo-$hash.cfg"
	if [ ! -f "$pathCfg" ]; then
		mkdir -p "$(dirname "$pathCfg")"
		echo "$cfg" > "$pathCfg"
	fi
	echo "-c $pathCfg $args"
}

exe_h264demo() { echo "$HW264_Encoder_DemoExe"; }
src_h264demo() { echo "Source = $1"; }
dst_h264demo() { echo "Destination = $1"; }
cmd_h264demo()
{
	local args= threads=1 res= bitrateKbps=2000
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args Source = $2";;
			-o|--output) 	args="$args Destination = $2";;
			   --res) 		args="$args Resolution = $2"
							args="$args StrideWH = $2";;
			   --fps) 		args="$args iInputFps = $2"
							args="$args fFrameRate = $2";;
			   --qp)     	args="$args iMinQP = $2"
							args="$args iMaxQP = $2";;
			   --bitrate)   bitrateKbps=$2;;
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done

	args="$args ThreadNum = $threads"
	args="$args iBitRate = $bitrateKbps"
	args="$args iMaxBitRate = $bitrateKbps"
	args="$args iKeyInterval = 0"
	args="$args iSliceBytes = 0"
	args="$args eProfile = 66"
	args="$args bFmo = 0"
	args="$args fPeakRatio = 5"
	args="$args iQuality = 1"
	args="$args iRefNum = 1"
	args="$args bCabac = 0"
	args="$args bDct8x8 = 0"
	args="$args eRcType = 0"
	args="$args Hierarchical = 0"
	args="$args svc = 0"
	args="$args Layernum = 0"
	args="$args bEnableROI = 0"
	args="$args iIntraMbIntervel = 0"
	args="$args iDesktopShare = 0"
	args="$args iSkipMode = 0"
	args="$args iFastEncode = 0"
	args="$args isAdaptQPmax = 0"
	args="$args bReconstuctFrame = 0"
	args="$args Framecount = 999999"

#	echo "$HW264_Encoder_DemoExe --test $args"
	echo "$HW264_Encoder_DemoExe $args"
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
#  426×240       24      250   400   700 0.10 0.17 0.29
#  640×360       24      500   800  1400 0.09 0.15 0.26
#  854×480       24      750  1200  2100 0.08 0.12 0.22
# 1280×720       24     1500  2400  4200 0.07 0.11 0.19
# 1920×1080      24     3000  4800  8400 0.06 0.10 0.17
# 4096×2160      24    10000 16000 28000 0.05 0.08 0.14

# https://developers.google.com/media/vp9/bitrate-modes
