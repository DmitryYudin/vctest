#
# For the sourcing.
#
# All exported functions are prefixed with "codec_".
#
# 	codec_default_preset (id) - 'preset' option value we consider as the default
#   codec_exe (id, target)    - path to executable module for a 'target' device
#	codec_hash(id, target)    - HASH
#	codec_cmdArgs(id, args)   - convert unified arguments to codec specific command line
#	codec_cmdHash(id, args)   - arguments HASH
#	codec_cmdSrc(id, src)     - set input file name
#	codec_cmdDst(id, src)     - set output file name
#

dirBinWindows="$dirScript/../bin/windows"
windows_ashevc="$dirBinWindows/ashevc/cli_ashevc.exe"
windows_x265="$dirBinWindows/x265/x265.exe"
windows_kvazaar="$dirBinWindows/kvazaar/kvazaar.exe"
windows_kingsoft="$dirBinWindows/kingsoft/AppEncoder_x64.exe"
windows_intel="$dirBinWindows/intel/sample_encode.exe"
windows_h265demo="$dirBinWindows/hw265/h265EncDemo.exe"
windows_h265demo_v2="$dirBinWindows/hw265_v2/hw265app.exe"
windows_h265demo_v3="$dirBinWindows/hw265_v3/hw265app.exe"
windows_h264demo="$dirBinWindows/hme264/HW264_Encoder_Demo.exe"
windows_h264aspt="$dirBinWindows/h264_aspt/h264enc.exe"
windows_vpx=$dirBinWindows/vpx/vpxenc.exe
windows_vp8=$windows_vpx
windows_vp9=$windows_vpx

dirBinAndroid="$dirScript/../bin/android"
android_kingsoft="$dirBinAndroid/kingsoft/appencoder"
android_ks="$dirBinAndroid/ks/ks_encoder"
android_h265demo="$dirBinAndroid/hw265/h265demo"
android_h265demo_v3="$dirBinAndroid/hw265_v3/hw265app"
android_x265="$dirBinAndroid/x265/x265"
android_h264aspt="$dirBinAndroid/h264_aspt/h264enc"
android_vpx=$dirBinAndroid/vpx/vpxenc
android_vp8=$android_vpx
android_vp9=$android_vpx

dirBinLinuxARM="$dirScript/../bin/linux-arm"
linux_arm_h265demo="$dirBinLinuxARM/hw265/h265demo"
linux_arm_h265demo_v2="$dirBinLinuxARM/hw265_v2/hw265app"
linux_arm_h265demo_v3="$dirBinLinuxARM/hw265_v3/hw265app"
linux_arm_ks="$dirBinLinuxARM/ks/ks_encoder"
linux_arm_x265="$dirBinLinuxARM/x265/x265"
linux_arm_h264aspt="$dirBinLinuxARM/h264_aspt/h264enc"
linux_arm_vpx=$dirBinLinuxARM/vpx/vpxenc
linux_arm_vp8=$linux_arm_vpx
linux_arm_vp9=$linux_arm_vpx

codec_get_knownId()
{
    REPLY=
    REPLY="$REPLY ashevc x265 kvazaar"
    REPLY="$REPLY kingsoft ks"
    REPLY="$REPLY intel_sw intel_hw"
    REPLY="$REPLY h265demo h265demo_v2 h265demo_v3"
    REPLY="$REPLY h264demo"
    REPLY="$REPLY h264aspt"
    REPLY="$REPLY vp8 vp9"
    REPLY=${REPLY# }
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
		ks)			preset=superfast;;
		intel_*)	preset=faster;;
		h265demo)	preset=5;;
		h265demo_v2)preset=6;; # 2,3,5,6
		h265demo_v3)preset=6;;
		h264demo)	preset=-;;
        h264aspt)	preset=3;; # 0 - 10
        vp8)	    preset=5;; # 0 - 16
        vp9)	    preset=9;; # 0 -  9
		*) error_exit "unknown encoder: $codecId";;
	esac
	REPLY=$preset
}
codec_exe()
{
	local codecId=$1; shift
	local target=$1; shift
	local encoderExe=

	eval "local cachedVal=\${CACHE_path_${codecId}_${target}:-}"
	if [[ -n "$cachedVal" ]]; then
		encoderExe=$cachedVal
	else
		exe_${codecId} $target; encoderExe=$REPLY
		[[ -f "$encoderExe" ]] || error_exit "encoder does not exist '$encoderExe'"
		encoderExe=$(ospath "$encoderExe")
		eval "CACHE_path_${codecId}_${target}=$encoderExe"
	fi

	REPLY=$encoderExe
}
codec_hash()
{
	local codecId=$1; shift
	local target=$1; shift
	local hash=

	eval "local cachedVal=\${CACHE_hash_${codecId}:-}"
	if [[ -n "$cachedVal" ]]; then
		hash=$cachedVal
	else
		local encoderExe
		codec_exe $codecId $target; encoderExe=$REPLY
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
    set -- $REPLY # remove extra spaces
	REPLY=$*
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
	src_${codecId} "$src"
}
codec_cmdDst()
{
	local codecId=$1; shift
	local dst=$1; shift
	dst_${codecId} "$dst"
}
codec_verify()
{
	local remote=$1; shift
	local target=$1; shift
	local CODECS="$*" codecId= cmd= codecList=
	local dirOut=$(mktemp -d)

	trap 'rm -rf -- "$dirOut"' EXIT
    local self=$(ospath "$dirScript/${BASH_SOURCE##*/}")

    # Avoid temporary files to appear in a root folder
    pushd "$dirOut" >/dev/null

	for codecId in $CODECS; do
		exe_${codecId} $target; encoderExe=$REPLY
		if [[ -z "$encoderExe" ]]; then
			echo "warning: no executable associated with '$codecId' codecId. Remove '$codecId' from a list." >&2
			continue
        fi
		if [[ ! -f "$encoderExe" ]]; then
			echo "warning: can't find '$encoderExe' executable. Remove '$codecId' from a list." >&2
			continue
		fi
		if $remote; then
			codecList="$codecList $codecId"
        else
			local cmd=$encoderExe
			# temporary hack, for backward compatibility (remove later)
			if [[ $codecId == h265demo ]]; then
				echo "" > h265demo.cfg
				cmd="$cmd -c h265demo.cfg"
			fi
			codec_cmdArgs $codecId --res 160x96 --fps 30; cmd="$cmd $REPLY"
			codec_cmdSrc $codecId "$self"; cmd="$cmd $REPLY"
			codec_cmdDst $codecId out.tmp; cmd="$cmd $REPLY"

			if ! { echo "yes" | $cmd; } 1>/dev/null 2>&1; then
				echo "warning: encoding error. Remove '$codecId' from a list." >&2;
            else
    			codecList="$codecList $codecId"
			fi
		fi
	done
    popd >/dev/null
	CODECS=${codecList# }

	rm -rf -- "$dirOut"
	trap -- EXIT

	if $remote; then
		# Push executable (folder content) on a target device
		local remoteDirBin
		TARGET_getExecDir; remoteDirBin=$REPLY/vctest/bin
		TARGET_exec "mkdir -p $remoteDirBin"
		print_console "Push codecs to remote machine $remoteDirBin ...\n"
		for codecId in $CODECS; do
            codec_exe $codecId $target; encoderExe=$REPLY
			TARGET_push "$(dirname $encoderExe)/." $remoteDirBin
			TARGET_exec "chmod +x $remoteDirBin/$(basename $encoderExe)"
	    done
	fi
	REPLY=$CODECS
}

exe_x265() { REPLY=;
			 [[ $1 == windows ]] && REPLY=$windows_x265;
			 [[ $1 == adb     ]] && REPLY=$android_x265;
			 [[ $1 == ssh     ]] && REPLY=$linux_arm_x265;
			 return 0;
}
src_x265() { REPLY="--input $1"; }
dst_x265() { REPLY="--output $1"; }
cmd_x265()
{
	local args= threads=0
	while [[ "$#" -gt 0 ]]; do
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

exe_ashevc() { REPLY=; [[ $1 == windows ]] && REPLY=$windows_ashevc; return 0; }
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

exe_kvazaar() { REPLY=; [[ $1 == windows ]] && REPLY=$windows_kvazaar; return 0; }
src_kvazaar() { REPLY="--input $1"; }
dst_kvazaar() { REPLY="--output $1"; }
cmd_kvazaar()
{
	local args= threads=0
	while [[ "$#" -gt 0 ]]; do
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

exe_kingsoft() { REPLY=;
				 [[ $1 == windows ]] && REPLY=$windows_kingsoft;
				 [[ $1 == adb     ]] && REPLY=$android_kingsoft;
				 return 0;
}
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

exe_ks() { REPLY=;
				 [[ $1 == adb ]] && REPLY=$android_ks;
				 [[ $1 == ssh ]] && REPLY=$linux_arm_ks;
				 return 0;
}
src_ks() { REPLY="-i $1"; }
dst_ks() { REPLY="-b $1"; }
cmd_ks()
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
	args="$args -refnum 1 -ref0 1"     # Num reference frames
	args="$args -lookahead 0"
	args="$args -bframes 0"			# Disable B-frames
	args="$args -iper -1"         	# Only first picture is intra.
#	args="$args -fpp 1" 			# TODO: enable frame level parallel

	REPLY=$args
}

cmd_intel()
{
	local args= threads=1 res=
	while [[ "$#" -gt 0 ]]; do
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

exe_intel_sw() { REPLY=; [[ $1 == windows ]] && REPLY=$windows_intel; return 0; }
src_intel_sw() { REPLY="-i $1"; }
dst_intel_sw() { REPLY="-o $1"; }
cmd_intel_sw() { cmd_intel "$@"; REPLY="$REPLY -sw"; }

exe_intel_hw() { REPLY=; [[ $1 == windows ]] && REPLY=$windows_intel; return 0; }
src_intel_hw() { REPLY="-i $1"; }
dst_intel_hw() { REPLY="-o $1"; }
cmd_intel_hw() { cmd_intel "$@"; REPLY="$REPLY -hw"; }

exe_h265demo() { REPLY=;
				 [[ $1 == windows ]] && REPLY=$windows_h265demo;
				 [[ $1 == adb     ]] && REPLY=$android_h265demo;
				 [[ $1 == ssh     ]] && REPLY=$linux_arm_h265demo;
				 return 0;
}
src_h265demo() { REPLY="-i $1"; }
dst_h265demo() { REPLY="-b $1"; }
cmd_h265demo()
{
	local args= threads=1 res= fps= preset=6
	while [[ "$#" -gt 0 ]]; do
		case $1 in
			-i|--input) 	args="$args -i $2";;
			-o|--output) 	args="$args -b $2";;
			   --res) 		res=$2;;
			   --fps) 		fps=$2;;
			   --preset) 	preset=$2;; # 0-7 or 1-7
#			   --preset)	args="$args -u $2";; # usage: veryslow(quality), slower, slow, medium(balanced), fast, faster, veryfast(speed)
			   --qp)     	args="$args -rc 2 -qp $2 -br 2000";;
			   --bitrate)   args="$args -rc 0 -qp 37 -br $2";;
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

#	args="$args -qp 37"  			# InitQP
	args="$args -channel 0"  		# ChannelID
	args="$args -profile 0"  		# Profile
	args="$args -keyInt 1000"		# IntraPeriod
	args="$args -fixed_keyInt 0"	# FixedIntraPeriod = 0,1
	args="$args -bframes 0"			# Bframes
	args="$args -bframeRef 1"		# BframeRef
	args="$args -fps_num $fps"		# FrameRateNum
	args="$args -fps_den 1"			# FrameRateDen
	args="$args -vfrinput 0"		# VfrInput
	args="$args -timebase_num 1"	# TimeBaseNum
	args="$args -timebase_den 25"	# TimeBaseDen
	args="$args -pass 0"			# Pass
	args="$args -crf 23"			# Crf
	args="$args -BitRatePAR 1"		# BitRatePAR
	args="$args -ParCovStrength 0"	# BitrateParCovStrength
	args="$args -adap_i 0"			# Adaptive_IFrame
	args="$args -LookAheadThreads 1" # LookAheadThreads
	args="$args -TotalDelayTime 0"	# EtoEDelayTime
	args="$args -delay 0"			# DelayNum
	args="$args -preset $preset"	# Preset
	args="$args -tune 0"			# Tune
	args="$args -debug_level 1"		# DebugLevel
	args="$args -pvc_level 0"		# PvcLevel
	args="$args -pvc_mode 0"		# PvcMode
	args="$args -pvc_strenght 0"	# PvcStrenght
	args="$args -psnr 0"			# PSNREnable
	args="$args -frames 9999"		# FramesToBeEncoded
	args="$args -fixsendyuv 0"		# FixTimeSendYUV

	REPLY=$args
}

exe_h265demo_v2() { REPLY=;
				 [[ $1 == windows ]] && REPLY=$windows_h265demo_v2;
				 [[ $1 == adb     ]] && REPLY=$android_h265demo_v2;
				 [[ $1 == ssh     ]] && REPLY=$linux_arm_h265demo_v2;
				 return 0;
}
src_h265demo_v2() { REPLY="-i $1"; }
dst_h265demo_v2() { REPLY="-b $1"; }
cmd_h265demo_v2()
{
	local args= threads=1 res= fps= preset=6
	while [[ "$#" -gt 0 ]]; do
		case $1 in
			-i|--input) 	args="$args -i $2";;
			-o|--output) 	args="$args -b $2";;
			   --res) 		res=$2;;
			   --fps) 		fps=$2;;
			   --preset) 	preset=$2;; # 2,3,5,6 <-> slow -> fast (default: 3)_
			   --qp)     	args="$args --rc 0 --qp $2";;
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done
	local width=${res%%x*}
	local height=${res##*x}
	args="$args -w $width"
	args="$args -h $height"
	args="$args --frames 9999"
	args="$args --channel 0"
	args="$args --fps $fps"
	args="$args --keyInt 500"
	args="$args --bframes 0"
	args="$args --bframe_ref 1"
	args="$args --frame_threads 1"
	args="$args --wpp_threads $threads"
	args="$args --profile 0"
	args="$args --qualityset $preset"
	REPLY=$args
}

exe_h265demo_v3() { REPLY=;
				 [[ $1 == windows ]] && REPLY=$windows_h265demo_v3;
				 [[ $1 == adb     ]] && REPLY=$android_h265demo_v3;
				 [[ $1 == ssh     ]] && REPLY=$linux_arm_h265demo_v3;
				 return 0;
}
src_h265demo_v3() { REPLY="-i $1"; }
dst_h265demo_v3() { REPLY="-b $1"; }
cmd_h265demo_v3()
{
	local args= threads=1 res= fps= preset=6
	while [[ "$#" -gt 0 ]]; do
		case $1 in
			-i|--input) 	args="$args -i $2";;
			-o|--output) 	args="$args -b $2";;
			   --res) 		res=$2;;
			   --fps) 		fps=$2;;
			   --preset) 	preset=$2;; # 2,3,5,6 <-> slow -> fast (default: 3)_
			   --qp)        args="$args -rc 0 -qp $2";;
			   --bitrate)   args="$args -rc 1 -br $2";;
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done
	local width=${res%%x*}
	local height=${res##*x}
	args="$args -w $width"
	args="$args -h $height"

	args="$args -frames 0"
	args="$args -channel 0"
	args="$args -fps $fps"
	args="$args -keyInt 500"
	args="$args -bframes 0"
	args="$args -bframe_ref 0"
	args="$args -frame_threads 1"
	args="$args -wpp_threads $threads"
	args="$args -profile 0"
	args="$args -qualityset $preset"
	args="$args -psnr 0"
	args="$args -svc 0"
	args="$args -tnum 0"

	REPLY=$args
}

exe_h264demo() { REPLY=; [[ $1 == windows ]] && REPLY=$windows_h264demo; return 0; }
src_h264demo() { REPLY="Source = $1"; }
dst_h264demo() { REPLY="Destination = $1"; }
cmd_h264demo()
{
	local args= threads=1 res= bitrateKbps=2000
	while [[ "$#" -gt 0 ]]; do
		case $1 in
			-i|--input) 	args="$args Source = $2";;
			-o|--output) 	args="$args Destination = $2";;
			   --res) 		args="$args Resolution = $2"
							args="$args StrideWH = $2";;
			   --fps) 		args="$args iInputFps = $2"
							args="$args fFrameRate = $2"
			        	    args="$args iMinQP = 1"
							args="$args iMaxQP = 51";;
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

	REPLY="--test $args"   # produce output, but have slow speed
#	REPLY="--speed $args"  # no output, but demonstrate high speed
}

exe_h264aspt() { REPLY=;
				 [[ $1 == windows ]] && REPLY=$windows_h264aspt;
				 [[ $1 == adb     ]] && REPLY=$android_h264aspt;
				 [[ $1 == ssh     ]] && REPLY=$linux_arm_h264aspt;
				 return 0;
}
src_h264aspt() { REPLY="-i $1"; }
dst_h264aspt() { REPLY="-o $1"; }
cmd_h264aspt()
{
	local args= threads=1 res=
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args -i $2";;
			-o|--output) 	args="$args -o $2";;
			   --res) 		res=$2;;
			   --fps) 		args="$args --fps $2";;
			   --preset) 	args="$args --quality $2";; # 0 (slow) - 10 (fast)
			   --qp)     	args="$args --bitrate 10000 --qpmin $2 --qpmax $2";; # any valid bitrate
			   --bitrate)   args="$args --bitrate $2";;
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done
	local width=${res%%x*}
	local height=${res##*x}
	args="$args -w $width"
	args="$args -h $height"

#	args="$args -threads $threads"
	args="$args --keyint 0"         	# Only first picture is intra.

	REPLY=$args
}

exe_VPX() { REPLY=;
				 [[ $1 == windows ]] && REPLY=$windows_vpx;
				 [[ $1 == adb     ]] && REPLY=$android_vpx;
				 [[ $1 == ssh     ]] && REPLY=$linux_arm_vpx;
				 return 0;
}
src_vpx() { REPLY="$1"; }
dst_vpx() { REPLY="-o $1"; }
cmd_vpx() # https://arxiv.org/pdf/2009.14165.pdf   [ we do not use --rt mode ]
{
	local args= threads=1 res=
	while [ "$#" -gt 0 ]; do
		case $1 in
			-i|--input) 	args="$args $2";;
			-o|--output) 	args="$args -o $2";;
			   --res) 		res=$2;;
			   --fps) 		args="$args --fps=$2/1";;
			   --preset) 	args="$args --cpu-used=$2";;
			   --qp)     	args="$args --target-bitrate=0  --end-usage=cq --cq-level=$2";; # any valid bitrate
			   --bitrate)   args="$args --target-bitrate=$2 --end-usage=cbr";; # --max-intra-rate=$((3 * $2))";;
			   --threads)   threads=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done
	local width=${res%%x*}
	local height=${res##*x}
	args="$args --width=$width --height=$height --threads=$threads"
    args="$args --i420 --ivf"
    args="$args --min-q=2 --max-q=56"
    args="$args --lag-in-frames=0 --drop-frame=0 --resize-allowed=0 --error-resilient=0"
    args="$args --undershoot-pct=100 --overshoot-pct=100"
    args="$args --buf-sz=1000 --buf-initial-sz=500 --buf-optimal-sz=600"
    args="$args --verbose"  # show settings
    args="$args --max-intra-rate=300 --disable-kf --kf-min-dist=90000 --kf-max-dist=90000"
    args="$args --passes=1" # vp9 uses two-pass by default

	REPLY=$args
}

exe_vp8() { exe_VPX "$@"; }
src_vp8() { src_vpx "$@"; }
dst_vp8() { dst_vpx "$@"; }
cmd_vp8() # https://www.webmproject.org/docs/encoder-parameters
{
    local args=;  # speed [0-16]: 0 - slowest; [4,5] - disable rdo
    cmd_vpx "$@"; args="$args $REPLY"

	args="$args --codec=vp8"
    REPLY=$args
}

exe_vp9() { exe_VPX "$@"; }
src_vp9() { src_vpx "$@"; }
dst_vp9() { dst_vpx "$@"; }
cmd_vp9()
{
    local args=; # speed [0-9]: 0 - slowest; [0,4] - VOD; [5-9] - Realtime
    cmd_vpx "$@"; args="$args $REPLY"

	args="$args --codec=vp9"
	args="$args --tile-columns=0"
    REPLY=$args
}
