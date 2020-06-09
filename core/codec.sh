#
# For the sourcing. 
#
# All exported functions are prefixed with "codec_".
#
# 	codec_default_preset (id) - 'preset' option value we consider as the default
#   codec_exe (id)            - path to executable module
#	codec_hash(id)            - HASH
#	codec_cmdArgs(id, args)   - convert unified arguments to codec specific command line
#	codec_cmdHash(id, args)   - arguments HASH
#	codec_cmdSrc(id, src)     - set input file name
#	codec_cmdDst(id, src)     - set output file name
#
if [ -z "${ashevcEncoderExe:-}" ]; then
readonly ashevcEncoderExe=$dirScript/../'bin/ashevc/cli_ashevc.exe'
readonly x265EncoderExe=$dirScript/../'bin/x265/x265.exe'
readonly kvazaarEncoderExe=$dirScript/../'bin/kvazaar/kvazaar.exe'
readonly kingsoftEncoderExe=$dirScript/../'bin/kingsoft/AppEncoder_x64.exe'
readonly intelEncoderExe=$dirScript/../'bin/intel/sample_encode.exe' # can't run HW.
readonly h265EncDemoExe=$dirScript/../'bin/hw265/h265EncDemo.exe'
readonly HW264_Encoder_DemoExe=$dirScript/../'bin/hme264/HW264_Encoder_Demo.exe'
fi

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

	REPLY=$preset
}
codec_exe()
{
	local codecId=$1 encoderExe=

	eval "local cachedVal=\${CACHE_path_${codecId}:-}"
	if [ -n "$cachedVal" ]; then
		encoderExe=$cachedVal
	else
		exe_${codecId}; encoderExe=$REPLY
		[ -f "$encoderExe" ] || error_exit "encoder does not exist '$encoderExe'"
		encoderExe=$(realpath "$encoderExe")
		eval "CACHE_path_${codecId}=$encoderExe"
	fi

	REPLY=$encoderExe
}
codec_hash()
{
	local codecId=$1 hash=

	eval "local cachedVal=\${CACHE_hash_${codecId}:-}"
	if [ -n "$cachedVal" ]; then
		hash=$cachedVal
	else
		local encoderExe
		codec_exe $codecId; encoderExe=$REPLY
		hash=$(md5sum ${encoderExe//\\//})
		hash=${hash% *}
		hash=${codecId}_${hash::8}
		eval "CACHE_hash_${codecId}=$hash"
	fi
	REPLY=$hash
}
codec_cmdArgs()
{
	local codecId=$1; shift
	cmd_${codecId} "$@"
	REPLY=${REPLY# }
	REPLY=${REPLY% }
}
codec_cmdHash()
{
	local src=$1; shift
	local args=$*; shift ; args=${args// /}   # remove all whitespaces
	local SRC=${src//\\/}; SRC=${SRC##*[/\\]} # basename only
	local hash=$(echo "$SRC $args" | md5sum | cut -d' ' -f1)
	REPLY=$hash
}
codec_cmdSrc()
{
	local codecId=$1; shift
	local src=$1; shift
	src_${codecId} "$(ospath $src)"
}
codec_cmdDst()
{
	local codecId=$1; shift
	local dst=$1; shift
	dst_${codecId} "$dst"
}
codec_verify()
{
	local CODECS="$*" codecId= cmd= removeList=
	local dirOut=$(ospath $(mktemp -d))

	trap 'rm -rf -- "$dirOut"' EXIT

	for codecId in $CODECS; do
		exe_${codecId}; encoderExe=$REPLY
		if ! [ -f "$encoderExe" ]; then
			echo "warning: can't find executable. Remove '$codecId' from a list."
			removeList="$removeList $codecId"
			continue
		fi

		local cmd=$encoderExe
		codec_cmdArgs $codecId --res 160x96 --fps 30; cmd="$cmd $REPLY"
		codec_cmdSrc $codecId "$0"; cmd="$cmd $REPLY"
		codec_cmdDst $codecId "$dirOut/out.tmp"; cmd="$cmd $REPLY"

		if ! { echo "yes" | $cmd; } 1>/dev/null 2>&1; then
			echo "warning: encoding error. Remove '$codecId' from a list." >&2;
			removeList="$removeList $codecId"
		fi
		rm -f "$dirOut/out.tmp"
	done

	rm -rf -- "$dirOut"
	trap -- EXIT

	for codecId in $removeList; do
		CODECS=$(echo "$CODECS" | sed "s/$codecId//")
	done
	REPLY=$CODECS
}

exe_x265() { REPLY=$x265EncoderExe; }
src_x265() { REPLY="--input $1"; }
dst_x265() { REPLY="--output $1"; }
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

	REPLY=$args
}

exe_ashevc() { REPLY=$ashevcEncoderExe; }
src_ashevc() { REPLY="--input $1"; }
dst_ashevc() { REPLY="--output $1"; }
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

	REPLY=$args
}

exe_kvazaar() { REPLY=$kvazaarEncoderExe; }
src_kvazaar() { REPLY="--input $1"; }
dst_kvazaar() { REPLY="--output $1"; }
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

	REPLY=$args
}

exe_kingsoft() { REPLY=$kingsoftEncoderExe; }
src_kingsoft() { REPLY="-i $1"; }
dst_kingsoft() { REPLY="-b $1"; }
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

	REPLY=$args
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

	REPLY="h265 $args"
}

exe_intel_sw() { REPLY=$intelEncoderExe; }
src_intel_sw() { REPLY="-i $1"; }
dst_intel_sw() { REPLY="-o $1"; }
cmd_intel_sw() { cmd_intel "$@"; REPLY="$REPLY -sw"; }

exe_intel_hw() { REPLY=$intelEncoderExe; }
src_intel_hw() { REPLY="-i $1"; }
dst_intel_hw() { REPLY="-o $1"; }
cmd_intel_hw() { cmd_intel "$@"; REPLY="$REPLY -hw"; }

exe_h265demo() { REPLY=$h265EncDemoExe; }
src_h265demo() { REPLY="-i $1"; }
dst_h265demo() { REPLY="-b $1"; }
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
	local _dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
	local pathCfg="$_dirScript/persistent/h265demo-$hash.cfg"
	if [ ! -f "$pathCfg" ]; then
		mkdir -p "$(dirname "$pathCfg")"
		echo "$cfg" > "$pathCfg"
	fi
	REPLY="-c $(ospath "$pathCfg") $args"
}

exe_h264demo() { REPLY=$HW264_Encoder_DemoExe; }
src_h264demo() { REPLY="Source = $1"; }
dst_h264demo() { REPLY="Destination = $1"; }
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

#	REPLY="--test $args"
	REPLY=$args
}
