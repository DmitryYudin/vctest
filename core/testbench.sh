set -eu -o pipefail

readonly dirScript="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

PRMS="28 34 39 44"
REPORT=report.log
REPORT_KW=report_kw.log
CODECS="ashevc x265 kvazaar kingsoft intel_sw intel_hw h265demo h264demo"
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
	    -p|--prms     Bitrate (kbps) or QP list. Default: "$PRMS".
	       --hide     Do not print legend and header
	Note, 'prms' values less than 60 considered as QP.
	EOF
}

entrypoint()
{
	local cmd_vec= cmd_report= cmd_codecs= cmd_prms= cmd_dirOut=
	local hide_banner=
	while [ "$#" -gt 0 ]; do
		local nargs=2
		case $1 in
			-h|--help)		usage && return;;
			-i|--in*) 		cmd_vec="$cmd_vec $2";;
			-d|--dir)		cmd_dirOut=$2;;
			-o|--out*) 		cmd_report=$2;;
			-c|--codec*) 	cmd_codecs=$2;;
			-p|--prm*) 		cmd_prms=$2;;
			   --hide)		hide_banner=1; nargs=1;;
			*) echo "error: unrecognized option '$1'" >&2 && return 1
		esac
		shift $nargs
	done
	[ -n "$cmd_dirOut" ] && DIR_OUT=$cmd_dirOut
	[ -n "$cmd_report" ] && REPORT=$cmd_report && REPORT_KW=${REPORT%.*}_kw.${REPORT##*.}
	[ -n "$cmd_vec" ] && VECTORS=${cmd_vec# }
	[ -n "$cmd_codecs" ] && CODECS=$cmd_codecs
	[ -n "$cmd_prms" ] && PRMS=$cmd_prms

	mkdir -p "$DIR_OUT"

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

		print_legend
		print_header
	fi

	local prm= src= codecId=
	for prm in $PRMS; do
	for src in $VECTORS; do
	for codecId in $CODECS; do
		local qp=- bitrate=-
		if [ $prm -lt 60 ]; then
			qp=$prm
		else
			bitrate=$prm
		fi

		local srcRes=$(detect_resolution_string "$src")
		[ -z "$srcRes" ] && echo "error: can't detect resolution for $src" >&2 && return 1
		local srcFps=$(detect_framerate_string "$src")
		local width=${srcRes%%x*}
		local height=${srcRes##*x}

		local srcNumFr=$(detect_frame_num "$src" "$srcRes")
		[ -z "$srcNumFr" ] && echo "error: can't detect number of frames for $src" >&2 && return 1

		local ext=h265; [ $codecId == h264demo ] && ext=h264

		local dst=
		if [ $bitrate == '-' ]; then
			dst=$DIR_OUT/$codecId/"$(basename "$src")".qp=$qp.$ext
		else
			dst=$DIR_OUT/$codecId/"$(basename "$src")".br=$bitrate.$ext
		fi
		local recon=$dst.yuv
		rm -rf "$dst" "$recon"

		# argument		
		set -- -i "$src" -o "$dst" --res "$srcRes" --fps $srcFps
		[ $bitrate == '-' ] || set -- "$@" --bitrate $bitrate
		[ $qp == '-' ]      || set -- "$@" --qp $qp
		case $codecId in
			ashevc) 	set -- "$@" --preset 5 ;; # 1 is fastest, 6 is slowest. default 5
			x264) 		set -- "$@" --preset "medium" ;;
			kvazaar) 	set -- "$@" --preset "medium" ;;
			kingsoft)	set -- "$@" --preset "medium" ;;
			intel_*)	set -- "$@" --preset "medium" ;;
			h265demo)	: ;;
			h264demo)	: ;;
		esac
		local cmd=
		cmd=$(cmd_${codecId} "$@")
		local info="codecId:$codecId srcRes:${width}x${height} srcFps:$srcFps srcNumFr:$srcNumFr QP:$qp BR:$bitrate SRC:$(basename $src)"
		print_info "$info"

		mkdir -p "$(dirname "$dst")"
		local stdoutLog=${dst%.*}.log
		echo "$codecId" > $stdoutLog
		echo "$cmd" >> $stdoutLog

		# Start CPU monitor
		start_cpu_monitor "$codecId" "$dst"

		# Encode
		local consumedSec=$(date +%s%3N) # seconds*1000

		if ! { echo "yes" | $cmd ;} 1>>$stdoutLog 2>&1 ; then
			printf "\nEncoding error, logs:\n"
			cat $stdoutLog
			return 1
		fi
		consumedSec=$(( $(date +%s%3N) - consumedSec ))

		# Stop CPU monitor
		local cpuAvg=$(stop_cpu_monitor "$dst")

		# Reconstruct
		$ffmpegExe -loglevel error -i "$dst" "$recon"

		local extFPS=0
		[ $consumedSec != 0 ] && extFPS=$(( 1000*srcNumFr/consumedSec ))
		local intFPS=$(parse_stdoutLog $stdoutLog)
		local kbps=$(parse_kbps "$dst" "$srcNumFr" "$srcFps")
		local framestat=$(parse_framestat "$src" "$dst" "$recon" "$srcRes")

		rm -f "$recon"

		local TAG="$(basename $src).QP=$qp.BR=$bitrate"
		print_report "extFPS:$extFPS intFPS:$intFPS cpu:$cpuAvg kbps:$kbps $framestat $info TAG:$TAG"
	done
	done
	done
}

PERF_ID=
start_cpu_monitor()
{
	local codecId=$1; shift
	local dst=$1; shift

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

	local cpuLog=${dst%.*}.cpu.log
	local name=$(basename "$encoderExe"); name=${name%.*}
	typeperf '\Process('$name')\% Processor Time' > $cpuLog &
	PERF_ID=$!
}
stop_cpu_monitor()
{
	local dst=$1; shift

	{ kill -s INT $PERF_ID && wait $PERF_ID; } || true 
	PERF_ID=

	local cpuLog=${dst%.*}.cpu.log
	local cpuAvg=$(parse_cpuLog $cpuLog)
	
	echo "$cpuAvg"
}

dict_getValue()
{
	local dict=$1 key=$2; val=${dict#*$key:};	
	val=${val#"${val%%[! $'\t']*}"} # Remove leading whitespaces 
	val=${val%%[ $'\t']*} # Cut everything after left most whitespace
	echo "$val"
}

print_legend()
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
	EOT
	)

	echo "$str" > /dev/tty
}

print_header()
{
	local str=
	printf 	-v str    "%6s %6s %5s %5s"                 extFPS intFPS cpu% kbps
	printf 	-v str "%s %3s %7s %6s %4s"          "$str" '#I' avg-I avg-P peak 
	printf 	-v str "%s %6s %6s %6s %6s"          "$str" gPSNR psnr-I psnr-P gSSIM
	printf 	-v str "%s %-8s %11s %5s %2s %6s %s" "$str" codecId resolution '#frm' QP BR SRC

	echo_console "$str" "\n"

	echo "$str" >> "$REPORT"
}

print_info()
{
	local dict="$*"
	local codecId=$(dict_getValue "$dict" codecId)
	local srcRes=$(dict_getValue "$dict" srcRes)
	local srcFps=$(dict_getValue "$dict" srcFps)
	local srcNumFr=$(dict_getValue "$dict" srcNumFr)
	local QP=$(dict_getValue "$dict" QP)
	local BR=$(dict_getValue "$dict" BR)
	local SRC=$(dict_getValue "$dict" SRC)

	local str=
	printf 	-v str    "%6s %6s %5s %5s"                 "" "" "" ""
	printf 	-v str "%s %3s %7s %6s %4s"          "$str" "" "" "" ""
	printf 	-v str "%s %6s %6s %6s %6s"          "$str" "" "" "" ""
	printf 	-v str "%s %-8s %11s %5s %2s %6s %s" "$str" "$codecId" "${srcRes}@${srcFps}" "$srcNumFr" "$QP" "$BR" "$SRC"

	echo_console "$str" "\r"
}

print_report()
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
	local SRC=$(dict_getValue "$dict" SRC)
	local TAG=$(dict_getValue "$dict" TAG)

	local str=
	printf 	-v str    "%6s %6.0f %5.0f %5.0f"           "$extFPS" "$intFPS" "$cpu" "$kbps"
	printf 	-v str "%s %3d %7d %6d %4.1f"        "$str" "$numI" "$avgI" "$avgP" "$peak"
	printf 	-v str "%s %6.2f %6.2f %6.2f %6.3f"  "$str" "$gPSNR" "$psnrI" "$psnrP" "$gSSIM"
	printf 	-v str "%s %-8s %11s %5d %2s %6s %s" "$str" "$codecId" "${srcRes}@${srcFps}" "$srcNumFr" "$QP" "$BR" "$SRC"

	echo_console "$str" "\n"
	echo "$str" >> $REPORT
}

echo_console() # str eol -> console
{
	# sugar
	if [ -t 1 ]; then
		if [ -z "${COLUMNS:-}" ]; then
			case $OS in *_NT) COLUMNS=$(mode.com 'con:' | grep -i Columns: | tr -d ' ' | cut -s -d':' -f2) && export COLUMNS; esac
		fi
	fi

	local str="$1"; shift
	local eol=""
	[ "$#" -gt 0 ] && eol=$1

	[ -n "${COLUMNS:-}" ] && [ "${#str}" -gt "${COLUMNS:-}" ] && str="${str:0:$((COLUMNS - 4))}..."
	printf "%s$eol" "$str" > /dev/tty
}

parse_framestat()
{
	local src=$1; shift
	local compr=$1; shift
	local recon=$1; shift
	local res=$1; shift
	local summary="${compr%.*}.summary.log"
	local dirRaw="$(dirname $compr)/raw"
	local frameinfo="$dirRaw/$(basename "$compr").frame.info.log"
	local framessim="$dirRaw/"$(basename "$compr")".frame.ssim.log"
	local framepsnr="$dirRaw/"$(basename "$compr")".frame.psnr.log"
	local frametype="$dirRaw/"$(basename "$compr")".frame.type.log"

	mkdir -p "$dirRaw"

	# can't pass 'C:/...' to ffmpeg filter args, use temporary file
	local framessimTmp=$(basename $framessim)
	{   # ignore output
		$ffmpegExe -hide_banner -s $res -i "$src" -s $res -i "$recon" -lavfi "ssim=stats_file=$framessimTmp" -f null - 2>&1 \
			| grep '\[Parsed_' | sed 's/.*SSIM //'
	} > /dev/null
	cat "$framessimTmp" | tr -d $'\r' > "$framessim" && rm "$framessimTmp"

	local framepsnrTmp=$(basename $framepsnr)
	{   # ignore output
		$ffmpegExe -hide_banner -s $res -i "$src" -s $res -i "$recon" -lavfi "psnr=stats_file=$framepsnrTmp" -f null - 2>&1 \
			| grep '\[Parsed_' | sed 's/.*PSNR //'
	} > /dev/null
	cat "$framepsnrTmp" | tr -d $'\r' > "$framepsnr" && rm "$framepsnrTmp"

	$ffprobeExe -v error -show_frames -i "$compr" | tr -d $'\r' > $frameinfo

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
		done < $frameinfo
	} > $frametype

	paste "$frametype" "$framepsnr" "$framessim" > $summary

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
		psnrI=$( grep -i 'type:I' "$summary" | sed 's/.* psnr_avg:\([^ ]*\).*/\1/' | countAverage )
		psnrP=$( grep -i 'type:P' "$summary" | sed 's/.* psnr_avg:\([^ ]*\).*/\1/' | countAverage )
	else                # GlobalPSNR( Avg(Y), Avg(U), Avg(V) ) <= x265
		local psnr_y=$( grep -i 'type:I' "$summary" | sed 's/.* psnr_y:\([^ ]*\).*/\1/' | countAverage )
		local psnr_u=$( grep -i 'type:I' "$summary" | sed 's/.* psnr_u:\([^ ]*\).*/\1/' | countAverage )
		local psnr_v=$( grep -i 'type:I' "$summary" | sed 's/.* psnr_v:\([^ ]*\).*/\1/' | countAverage )
		psnrI=$(echo "$psnr_y" "$psnr_u" "$psnr_v" | countGlobalPSNR)

		local psnr_y=$( grep -i 'type:P' "$summary" | sed 's/.* psnr_y:\([^ ]*\).*/\1/' | countAverage )
		local psnr_u=$( grep -i 'type:P' "$summary" | sed 's/.* psnr_u:\([^ ]*\).*/\1/' | countAverage )
		local psnr_v=$( grep -i 'type:P' "$summary" | sed 's/.* psnr_v:\([^ ]*\).*/\1/' | countAverage )
		psnrP=$(echo "$psnr_y" "$psnr_u" "$psnr_v" | countGlobalPSNR)
	fi
	{
		local psnr_y=$( cat "$summary" | sed 's/.* psnr_y:\([^ ]*\).*/\1/' | countAverage )
		local psnr_u=$( cat "$summary" | sed 's/.* psnr_u:\([^ ]*\).*/\1/' | countAverage )
		local psnr_v=$( cat "$summary" | sed 's/.* psnr_v:\([^ ]*\).*/\1/' | countAverage )
		gPSNR=$(echo "$psnr_y" "$psnr_u" "$psnr_v" | countGlobalPSNR)
	}

	local ssimI= ssimP= gSSIM=
	if [ 0 == 1 ]; then # Full
		ssimI=$( grep -i 'type:I' "$summary" | sed 's/.* All:\([^ ]*\).*/\1/' | countAverage )
		ssimP=$( grep -i 'type:P' "$summary" | sed 's/.* All:\([^ ]*\).*/\1/' | countAverage )
		gSSIM=$(              cat "$summary" | sed 's/.* All:\([^ ]*\).*/\1/' | countAverage )
	else                # Luma <= x265 reports only Y-SSIM
		ssimI=$( grep -i 'type:I' "$summary" | sed 's/.* Y:\([^ ]*\).*/\1/' | countAverage )
		ssimP=$( grep -i 'type:P' "$summary" | sed 's/.* Y:\([^ ]*\).*/\1/' | countAverage )
		gSSIM=$(              cat "$summary" | sed 's/.* Y:\([^ ]*\).*/\1/' | countAverage )
	fi

	local avgI=0 avgP=0
	[ $numI != 0 ] && avgI=$(( sizeI / numI ))
	[ $numP != 0 ] && avgP=$(( sizeP / numP ))
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
		*) echo "unknown encoder($LINENO): $codecId" >&2 && return 1 ;;
	esac
	echo "$fps"
}

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
			*) echo "error: unrecognized option '$1'" 1>&2 && return 1;
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

	echo "$x265EncoderExe $args"
}

cmd_ashevc()
{
	local args= threads=1 res=
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args --input $2";;
			-o|--output) 	args="$args --output $2";;
			   --res) 		res=$2;;
			   --fps) 		args="$args --fps $2";;
			   --preset) 	args="$args --preset $2";; # 1 ~ 6: 1 is fastest, 6 is slowest. default 5
			   --qp)     	args="$args --qp $2      --rc 12";; # rc=12: CQP
			   --bitrate)   args="$args --bitrate $2 --rc 8";;  # rc=8: ABR
			   --threads)   threads=$2;;
			*) echo "error: unrecognized option '$1'" 1>&2 && return 1;
		esac
		shift 2
	done
	local width=${res%%x*}
	local height=${res##*x}
	args="$args --width $width"
	args="$args --height $height"

	args="$args --wpp-threads $threads" # 0: Process everything with main thread.
	args="$args --ref 1"           	# Num reference frames
	args="$args --bframes 0"		# Disable B-frames
	args="$args --lookaheadnum 0 --lookahead-threads 0"
	args="$args --frame-threads 1"	# Does it have the same meaning as for x265?
	args="$args --keyint 999999"	# Only first picture is intra.
	args="$args --psnr 1"
	args="$args --ssim 1"

	echo "$ashevcEncoderExe $args"

}
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
			*) echo "error: unrecognized option '$1'" 1>&2 && return 1;
		esac
		shift 2
	done

	args="$args --threads $threads" # 0: Process everything with main thread.
	args="$args --ref 1"           	# Num reference frames
	args="$args --no-bipred --gop 0" # Disable B-frames
	args="$args --owf 0" 			# Frame-level parallelism. Process N+1 frames at a time.
	args="$args --period 0"         # Only first picture is intra.

	echo "$kvazaarEncoderExe $args"
}

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
			*) echo "error: unrecognized option '$1'" 1>&2 && return 1;
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

	echo "$kingsoftEncoderExe $args"
}

cmd_intel_sw()
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
			*) echo "error: unrecognized option '$1'" 1>&2 && return 1;
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
	args="$args -sw"				# Software
#	args="$args -hw"				# Hardware (default)

	echo "$intelEncoderExe h265 $args"
}
cmd_intel_hw() 
{
	echo "$(cmd_intel_sw "$@") -hw"
}

cmd_h265demo()
{
	local args= threads=1 res= dst= fps=
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args -i $2";;
			-o|--output) 	args="$args -b $2" dst=$2;;
			   --res) 		res=$2;;
			   --fps) 		fps=$2;;
#			   --preset) 	args="$args -preset $2";; # default, dss, conference, gaming
#			   --preset)	args="$args -u $2";; # usage: veryslow(quality), slower, slow, medium(balanced), fast, faster, veryfast(speed)
			   --qp)     	args="$args -rc 2 -qp $2";;
			   --bitrate)   args="$args -rc 0 -br $2";;
			   --threads)   threads=$2;;
			*) echo "error: unrecognized option '$1'" 1>&2 && return 1;
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
		Preset = 7
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
	mkdir -p "$(dirname "$dst")"
	echo "$cfg" > $dst.cfg

	echo "$h265EncDemoExe -c $dst.cfg $args"
}

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
			*) echo "error: unrecognized option '$1'" 1>&2 && return 1;
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

detect_resolution_string()
{	
	local filename=$1; shift
	local name=$(basename "$filename")
	name=${name%%.*}
	local res=

	# Upper case
	name=$(echo "$name" | tr a-z A-Z)

	# try HxW pattern delimited by "." or "_"
	for delim in _ .; do
		local IFS=$delim
		for i in $name; do
			if [[ "$i" =~ ^[1-9][0-9]{1,3}X[1-9][0-9]{1,3}$ ]]; then
				res=$i && break
			fi
		done
		[ -n "$res" ] && break
	done
	[ -n "$res" ] && { echo "$res" | tr X x; } && return

	# try abbreviations CIF, QCIF, ... delimited by "." or "_"
	for delim in _ .; do
		local IFS=$delim
		for i in $name; do
			case $i in # https://en.wikipedia.org/wiki/Common_Intermediate_Format
				 NTSC)	res=352x240;;   # 30 fps (11:9)  <=> SIF
				SQSIF)	res=128x96;;
				 QSIF)	res=176x120;;
			  	  SIF) 	res=352x240;;
				 2SIF) 	res=704x240;;
				 4SIF) 	res=704x480;;
				16SIF)	res=1408x960;;

				  PAL)	res=352x288;;   # 25 fps         <=> CIF
				SQCIF)	res=128x96;;
				 QCIF)	res=176x144;;
			 	  CIF) 	res=352x288;;
				 2CIF) 	res=704x288;;   # Half D1
				 4CIF) 	res=704x576;;   # D1
				16CIF)	res=1408x1152;;

				720P)   res=1280x720;;
			   1080P)   res=1920x1080;;
			   1440P) 	res=2560x1440;;
			   2160P) 	res=3840x2160;;
			   4320P) 	res=7680x4320;;

			      2K)   res=1920x1080;; # or 2560x1440
			      4K) 	res=3840x2160;;
			      8K) 	res=7680x4320;;
			esac
			[ -n "$res" ] && break
		done
		[ -n "$res" ] && break
	done
	[ -n "$res" ] && echo "$res" && return

	echo "error: can't detect resolution $filename" >&2
	return 1
}

detect_framerate_string()
{	
	local filename=$1; shift
	local name=$(basename "$filename")
	name=${name%%.*}
	local framerate=

	# Upper case
	name=$(echo "$name" | tr a-z A-Z)

	# try XXX pattern delimited by "." or "_"
	for delim in _ .; do
		local IFS=$delim
		for i in $name; do
			if [[ "$i" =~ ^[1-9][0-9]{0,2}(FPS)?$ ]]; then
				framerate=${i%FPS} && break
			fi
		done
		[ -n "$framerate" ] && break
	done
	[ -z "$framerate" ] && framerate=30
	echo "$framerate"
}

detect_frame_num()
{
	local filename=$1; shift
	local res=${1:-};
	if [ -z "$res" ]; then
		res=$(detect_resolution_string "$filename")
	fi
	[ -z "$res" ] && return

	local numBytes=$(stat -c %s "$filename")
	[ -z "$numBytes" ] && return 1

	local width=${res%%x*}
	local height=${res##*x}
	local numFrames=$(( 2 * numBytes / width / height / 3 )) 
	local numBytes2=$(( 3 * numFrames * width * height / 2 ))
	[ $numBytes != $numBytes2 ] && echo "error: can't detect frames number $filename" >&2 && return 1
	echo $numFrames
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
