#!/bin/bash
#
# Copyright © 2019 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#
set -eu -o pipefail

dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
. $dirScript/utility_functions.sh
. $dirScript/codec.sh
. $dirScript/remote_target.sh
. $dirScript/condor.sh

PRMS=-
REPORT=report.log
CODECS=
PRESET=
THREADS=
EXTRA=
KEYS="gPSNR gSSIM"
VECTORS=
DIR_BIN=$(ospath $dirScript/../bin)
DIR_OUT=$(ospath $dirScript/../out)
DIR_VEC=$(ospath $dirScript/../vectors)
NCPU=0
TRACE_HM=0
ENABLE_CPU_MONITOR=1

readonly parsePy=$dirScript/../'core/parseTrace.py'

usage()
{
	cat	<<-EOF
	Usage:
	    $(basename $0) [opt]

	Options:
	    -h|--help        Print help.
	    -i|--input   <x> Input YUV files relative to '/vectors' directory. Multiple '-i vec' allowed.
	                     '/vectors' <=> '$(ospath "$dirScript/../vectors")'
	    -o|--output  <x> Report path. Default: "$REPORT".
	       --bdrate      Generate BD-rate report
	       --keys    <x> BD-rate report keys (default: $KEYS)
	    -c|--codec   <x> Codecs list.
	    -t|--threads <x> Number of threads to use
	    -p|--prms    <x> Bitrate (kbps) or QP list. Default: "$PRMS".
	                     Values less than 60 considered as QP.
	       --preset  <x> Codec-specific 'preset' options (default: marked by *):
	                       ashevc:   *1 2 3 4 5 6
	                       x265:     *ultrafast  superfast veryfast  faster fast medium slow slower veryslow placebo
	                       kvazaar:  *ultrafast  superfast veryfast  faster fast medium slow slower veryslow placebo
	                       kingsoft:  ultrafast *superfast veryfast         fast medium slow        veryslow placebo
	                       ks:        ultrafast *superfast veryfast         fast medium slow        veryslow placebo
	                       intel_sw:                       veryfast *faster fast medium slow slower veryslow
	                       intel_hw:                       veryfast  faster fast medium slow slower veryslow
	                       h265demo: 6 *5 4 3 2 1
	                       h265demo_v2: 6 *5   3 2
	                       h264demo: N/A
	                       h264aspt: 0 (slow) - 10 (fast)
	                       vp8: 0 (slow) - 16 (fast)
	                       vp9: 0 (slow) -  9 (fast)
	                       vvenc*: *faster, fast, medium, slow, slower
	       --extra   <x> List of additional codec-specific parameters to append to the end of arguments list
	    -j|--ncpu    <x> Number of encoders to run in parallel. The value of '0' will run as many encoders as many
	                     CPUs available. Default: $NCPU
	                     Note, execution time based profiling data (CPU consumption and FPS estimation) is not
	                     available in parallel execution mode.
	       --adb         Run Android@ARM using ADB. | Credentials are read from 'remote.local' file.
	       --ssh         Run Linux@ARM using SSH.   |         (see example for details)
	       --condor      Run with Condor
	       --force       Invalidate results cache
	       --decode      Force decode stage
	       --parse       Force parse stage
	       --trace_hm    Collect H.265 stream info from HW decoder trace
	       --nomon       Disable CPU monitor
	EOF
}

entrypoint()
{
    # always access decoders thought PATH (i.e. system wide or residing in ../bin folder)
    update_PATH $dirScript/../bin
    export PATH

    local target transport=local
    case ${OS:-} in
        *_NT) target=${target:-windows};;
        *) target=${target:-linux};;
    esac

    local timestamp=$(date "+%Y.%m.%d-%H.%M.%S")
	local endofflags=
	local force= parse= decode= bdrate=
	while [[ $# -gt 0 ]]; do
		local nargs=2
		case $1 in
			-h|--help)		usage && return;;
			-i|--in*) 		VECTORS="$VECTORS $2";;
			-o|--out*) 		REPORT=${2//\\//};;
			   --bdrate) 	bdrate=1; nargs=1;;
			   --keys) 	    KEYS=$2;;
			-c|--codec*) 	CODECS=$2;;
			-t|--threads)   THREADS=$2;;
			-p|--prms) 		PRMS=$2;;
			   --preset) 	PRESET=$2;;
			   --extra) 	EXTRA=$2;;
			-j|--ncpu)		NCPU=$2;;
			   --adb)       target=adb; transport=adb; nargs=1;;
			   --ssh)       target=ssh; transport=ssh; nargs=1;;
			   --condor)    target=linux; transport=condor; nargs=1;;
               --force)     force=1; nargs=1;;
               --decode)    decode=1; nargs=1;;
               --parse)     parse=1; nargs=1;;
               --trace_hm)  TRACE_HM=1; nargs=1;;
               --nomon)     ENABLE_CPU_MONITOR=; nargs=1;;
			   --)			endofflags=1; nargs=1;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift $nargs
		[[ -n $endofflags ]] && break
	done
    local dirTmp=$(tempdir)/vctest/$timestamp

    VECTORS=${VECTORS# }
	# for multithreaded run, run in single process to get valid cpu usage estimation
	[[ -n $THREADS && $THREADS -gt 1 ]] && NCPU=1

	local targetInfo=
	if [[ $transport == adb || $transport == ssh ]] ; then
		TARGET_setTarget $target $dirScript/../remote.local
		TARGET_getFingerprint; targetInfo=$REPLY
	fi
	if [[ -n $endofflags ]]; then
		echo "exe: $@"
		"$@"
		return $?
	fi

	mkdir -p $DIR_OUT $(dirname $REPORT)

	# Remove non-existing and set abs-path
    print_console "Verify test vectors...\n"
	vectors_verify $transport $VECTORS; VECTORS=$REPLY

	# Remove codecs we can't run
    print_console "Verify codecs...\n"
	codec_verify $transport $target "$CODECS"; CODECS=$REPLY
    [[ -z "$CODECS" ]] && error_exit "no codecs to test"

	local startSec=$SECONDS

    mkdir -p $dirTmp

    local CODEC_CNT= # just for the progress display
    codecopt_init "$CODECS"
    while codecopt_next; do
        local CODEC_LONG=$REPLY
        CODEC_CNT="$CODEC_CNT x"
    done

    local do_encdec=
#   [[ $transport == local ]] && do_encdec=1
    [[ $transport == condor ]] && do_encdec=1

    local num_stages=5
    [[ -n $do_encdec ]] && num_stages=$((num_stages-1))
    [[ -n $bdrate ]] && num_stages=$((num_stages+1))
    progress_init $num_stages

	#
	# Scheduling
	#
	progress_begin "Scheduling..." "$PRMS" "$VECTORS" "$CODEC_CNT"

	local optionsFile=$dirTmp/options.txt
	prepare_optionsFile $target "$optionsFile" "$CODECS"

	local encodeList= decodeList= parseList= encdecList=
	while read info; do
		local encExeHash encCmdHash encFmt
		dict_getValue "$info" encExeHash; encExeHash=$REPLY
		dict_getValue "$info" encCmdHash; encCmdHash=$REPLY
        dict_getValue "$info" encFmt; encFmt=$REPLY
		local outputDirRel=$encExeHash/$encCmdHash
		local outputDir=$DIR_OUT/$outputDirRel

		local do_encode= do_decode= do_parse=

        [[ -n $force ]] && do_encode=1
        [[ -z $do_encode && ! -f $outputDir/encoded.ts ]] && do_encode=1

        [[ -n $do_encode ]] && do_decode=1
		[[ -n $decode ]] && do_decode=1
        [[ -z $do_decode && ! -f $outputDir/decoded.ts ]] && do_decode=1
        if [[ -z $do_decode && "$TRACE_HM" == 1 ]]; then
            [[ $encFmt == h265 && ! -f $outputDir/decoded_trace_hm ]] && do_decode=1
        fi

        [[ -n $do_decode ]] && do_parse=1
        [[ -n $parse ]] && do_parse=1
        [[ -z $do_parse && ! -f $outputDir/parsed.ts ]] && do_parse=1
		if [[ -n $do_encode ]]; then
			# clean up target directory if we need to start from a scratch
			rm -rf $outputDir		# this also force decoding and parsing
			mkdir -p $outputDir
			# readonly kw-file will be used across all processing stages
			echo "$info" > $outputDir/info.kw
        elif [[ -n $do_decode ]]; then
            rm -f $outputDir/parsed_* $outputDir/parsed.ts $outputDir/decoded_* $outputDir/decoded.ts
        elif [[ -n $do_parse ]]; then
            rm -f $outputDir/parsed_* $outputDir/parsed.ts
		fi

        [[ -n $do_encode ]] && encodeList="$encodeList $outputDirRel"
        [[ -n $do_encode || \
           -n $do_decode ]] && encdecList="$encdecList $outputDirRel"
        [[ -n $do_decode ]] && decodeList="$decodeList $outputDirRel"
        [[ -n $do_parse ]]  && parseList="$parseList $outputDirRel"

		progress_next $outputDirRel

	done < $optionsFile
	rm -f $optionsFile
	progress_end

	local self
	relative_path "$0"; self=$REPLY # just to make output look nicely

    # sort descending by input size to execute long test first
    if [[ $transport == condor && -n "$encdecList" ]]; then
        local files=
        for outputDirRel in $encdecList; do
            local info
            { read -r info; } < $DIR_OUT/$outputDirRel/info.kw
            dict_getValue "$info" src; src=$REPLY
            [[ -f ${src%.*}.nut ]] && src=${src%.*}.nut
            files="$files $src"
        done
    	local sizesFile=$(mktemp)
        { cd $DIR_VEC >/dev/null; stat -L -c %s $files; cd - >/dev/null; } > $sizesFile

        encdecList=$(for outputDirRel in $encdecList; do read -r; echo "$REPLY $outputDirRel"; done <$sizesFile | 
                sort -k1 -n -r | 
                awk '{ $1=""; printf "%s ", $0 }'; )
        rm $sizesFile
    fi

	local testplan=$dirTmp/testplan.txt

    if [[ -n $do_encdec ]]; then
    	#
	    # Encoding + Decoding
    	#
    	progress_begin "Encoding + Decoding..." "$encdecList"
	    if [[ -n "$encdecList" ]]; then
	    	if [[ $transport == condor ]]; then
    	    	CONDOR_setBatchname msk_$timestamp
			    for outputDirRel in $encdecList; do
				    encdec_single_file $transport $outputDirRel
    			done > $dirTmp/submit_encdec.log
	    		CONDOR_wait
		    	for outputDirRel in $encdecList; do
			    	local outputDir=$DIR_OUT/$outputDirRel
				    [[ ! -f $outputDir/encoded.ts ]] && error_exit "encoding failed $outputDirRel"
				    [[ ! -f $outputDir/decoded.ts ]] && error_exit "decoding failed $outputDirRel"
    			done
	    	else
                local cpumon=
                [[ -z $ENABLE_CPU_MONITOR ]] && cpumon=--nomon
		    	for outputDirRel in $encdecList; do
    		    	echo "$self --ncpu $NCPU $cpumon -- encdec_single_file $transport $outputDirRel"
	    		done > $testplan
		   		execute_plan $testplan $dirTmp $NCPU
	   		fi
    	fi
    	progress_end
    else
		#
		# Encoding
    	#
    	progress_begin "Encoding..." "$encodeList"
		if [[ -n "$encodeList" ]]; then
			if [[ $transport == condor ]]; then
    			CONDOR_setBatchname msk_e_$timestamp
				for outputDirRel in $encodeList; do
					encode_single_file $transport $outputDirRel
				done > $dirTmp/submit_encoder.log
				CONDOR_wait
				for outputDirRel in $encodeList; do
					local outputDir=$DIR_OUT/$outputDirRel
					[[ ! -f $outputDir/encoded.ts ]] && error_exit "encoding failed $outputDirRel"
				done
			else
				local cpumon=
				[[ -z $ENABLE_CPU_MONITOR ]] && cpumon=--nomon
				for outputDirRel in $encodeList; do
					echo "$self --ncpu $NCPU $cpumon -- encode_single_file $transport $outputDirRel"
				done > $testplan
	    		execute_plan $testplan $dirTmp $NCPU
			fi
		fi
		progress_end

    	#
    	# Decoding
    	#
    	NCPU=-2 # use (all+1) cores for decoding
    	progress_begin "Decoding..." "$decodeList"
    	if [[ -n "$decodeList" ]]; then
    		if [[ $transport == condor ]]; then
        		CONDOR_setBatchname msk_d_$timestamp
        		for outputDirRel in $decodeList; do
    	    		decode_single_file $transport $outputDirRel
    			done > $dirTmp/submit_decoder.log
    			CONDOR_wait
    			for outputDirRel in $decodeList; do
    				local outputDir=$DIR_OUT/$outputDirRel
    				[[ ! -f $outputDir/decoded.ts ]] && error_exit "decoding failed $outputDirRel"
    			done
            else
				for outputDirRel in $decodeList; do
					echo "$self -- decode_single_file $transport $outputDirRel"
				done > $testplan
				execute_plan $testplan $dirTmp $NCPU
			fi
    	fi
    	progress_end
    fi
	#
	# Parsing
	#
	NCPU=-3 # use (all + 2) cores
	progress_begin "Parsing..." "$parseList"
	if [[ -n "$parseList" ]]; then
		for outputDirRel in $parseList; do
			echo "$self -- parse_single_file $outputDirRel"
		done > $testplan
		execute_plan $testplan $dirTmp $NCPU
	fi
	progress_end

	rm -f -- $testplan

    #
    # Backup executables
    #
    codecopt_init "$CODECS"
    while codecopt_next; do
        local CODEC_LONG=$REPLY

        codecopt_parse "$CODEC_LONG"
        local codecId=${REPLY%%:*};

        local backupDir encoderDir
		codec_hash $codecId $target; backupDir=$DIR_OUT/$REPLY/exe
        [[ -d $backupDir ]] && continue
        codec_exe $codecId $target; encoderDir=$(dirname $DIR_BIN/$REPLY)
        mkdir -p ${backupDir}_tmp
        cp -f $encoderDir/* ${backupDir}_tmp
        mv ${backupDir}_tmp ${backupDir}
    done

	#
	# Reporting
	#
	progress_begin "Reporting..." "$PRMS" "$VECTORS" "$CODEC_CNT"

   	local test_info="$timestamp $target:$transport [PRMS:$PRMS][EXTRA:$EXTRA]${targetInfo:+[$targetInfo]}"

    # Add all CODECS_LONG to argument list
    codecopt_init "$CODECS" "$PRESET" "$THREADS" ""
    set --
    while codecopt_next; do
        local CODEC_LONG=$REPLY
        set -- "$@" "$CODEC_LONG"
    done

    # Generate optionFile(s) to process individual CODEC_LONG
    local report_idx=0 CODEC_LONG=
    for CODEC_LONG; do
	    local optionsFile=$dirTmp/options_report-$report_idx.txt
    	prepare_optionsFile $target $optionsFile "$CODEC_LONG"
        report_idx=$((report_idx+1))
    done

    # Report
    local report_idx=0 CODEC_LONG=
    for CODEC_LONG; do
	    local optionsFile=$dirTmp/options_report-$report_idx.txt
    	local reportList= info exeHash
    	while read info; do
	    	local encExeHash encCmdHash
    		dict_getValue "$info" encExeHash; encExeHash=$REPLY
	    	dict_getValue "$info" encCmdHash; encCmdHash=$REPLY
    		local outputDirRel=$encExeHash/$encCmdHash
    		reportList="$reportList $outputDirRel"
            exeHash=$encExeHash
        done<$optionsFile

        local report=$REPORT report_kw=/dev/null
        if [[ -n $bdrate ]]; then
            report=$DIR_OUT/bdrate_${timestamp}_${report_idx}.log
            report_kw=$DIR_OUT/bdrate_${timestamp}_${report_idx}.kw
        fi

        if [[ $report_idx == 0 ]]; then

            output_legend

            echo "$test_info" | tee -a $report $report_kw >/dev/null
        fi


        local tag=
        codecop_get_tag "$CODEC_LONG" $exeHash; tag=$REPLY

        echo "tst:$tag" >> $report
        output_header >> $report

    	for outputDirRel in $reportList; do
    		progress_next $outputDirRel
	    	report_single_file $report $report_kw $outputDirRel
        done

        report_idx=$((report_idx+1))
    done
   	progress_end

	#
	# Report bdrate
	#
    if [[ -n $bdrate ]]; then
    	progress_begin "BD-Rate..." "$CODEC_CNT"
        local report_idx=0 ref_kw CODEC_LONG= ref_tag
        for CODEC_LONG; do
    	    local optionsFile=$dirTmp/options_report-$report_idx.txt
    
        	local reportList= exeHash= info outputDirRel=
        	while read info; do
    	    	local encExeHash encCmdHash
        		dict_getValue "$info" encExeHash; encExeHash=$REPLY
    	    	dict_getValue "$info" encCmdHash; encCmdHash=$REPLY
    		    outputDirRel=$encExeHash/$encCmdHash # report only
                exeHash=$encExeHash # memorize for later use
                break
            done<$optionsFile
        	progress_next $outputDirRel

            local report=$DIR_OUT/bdrate_${timestamp}_${report_idx}.log
            local report_kw=$DIR_OUT/bdrate_${timestamp}_${report_idx}.kw
            local report_bdrate=$DIR_OUT/bdrate_${timestamp}.log
            local tag=
            codecop_get_tag "$CODEC_LONG" $exeHash; tag=$REPLY

            if [[ $report_idx == 0 ]]; then
                echo "$test_info" | tee -a $REPORT $report_bdrate >/dev/null
                ref_kw=$report_kw
                ref_tag=$tag
            else
                echo "tst:$tag ref:$ref_tag" | tee -a $REPORT $report_bdrate >/dev/null
                $dirScript/bdrate/bdrate.sh -i $ref_kw -i $report_kw --key "$KEYS" | tee -a $REPORT $report_bdrate >/dev/null
            fi

            report_idx=$((report_idx+1))
        done
    	progress_end
    fi

    local report_idx=0 CODEC_LONG=
    for CODEC_LONG; do
	    local optionsFile=$dirTmp/options_report-$report_idx.txt
        rm -f $optionsFile
    done

	local duration=$(( SECONDS - startSec ))
	duration=$(date +%H:%M:%S -u -d @${duration})
	print_console "$duration >>>> $REPORT $test_info\n"

    if [[ -n $bdrate ]]; then
        local report_bdrate=$DIR_OUT/bdrate_${timestamp}.log
        grep -e '<<< average >>>' -e '^tst:' -e '^ref:' $report_bdrate
    fi
}

vectors_verify()
{
	local transport=$1; shift
	local VECTORS="$*"

	local VECTORS_REL= vec=
	for vec in $VECTORS; do
		if [[ -f $DIR_VEC/$vec ]]; then
            relative_path $DIR_VEC/$vec $DIR_VEC; vec=$REPLY # normalize name if any
			VECTORS_REL="$VECTORS_REL $vec"
		else
			echo "warning: can't find vector in '$DIR_VEC'. Remove '$vec' from a list." >&2
		fi
	done
	VECTORS=${VECTORS_REL# }

	if [[ $transport == adb || $transport == ssh ]]; then
		local remoteDirVec= targetDirPrev=
		TARGET_getDataDir; remoteDirVec=$REPLY/vctest/vectors
		print_console "Push vectors to remote machine $remoteDirVec ...\n"
		for vec in $VECTORS_REL; do
            print_console "$vec\r"
            local targetDir=$remoteDirVec/${vec%"${vec##*/}"}
            if [[ "$targetDirPrev" != $targetDir ]]; then
        		TARGET_exec "mkdir -p $targetDir"
                targetDirPrev=$targetDir
            fi
			TARGET_pushFileOnce $DIR_VEC/$vec $remoteDirVec/$vec
		done
	fi
	REPLY=$VECTORS
}

prepare_optionsFile()
{
	local target=$1; shift
	local optionsFile=$1; shift
    local CODECS="$@"

    prepare_options() {
        local CODEC_LONG=$1; shift
        local prm=$1; shift
        local src=$1; shift

        codecopt_parse "$CODEC_LONG"
        local codecId=${REPLY%%:*}; REPLY=${REPLY#${REPLY%%:*}:}
        local codec_prms=${REPLY%%:*}; REPLY=${REPLY#${REPLY%%:*}:}
        local codec_preset=${REPLY%%:*}; REPLY=${REPLY#${REPLY%%:*}:}
        local codec_threads=${REPLY%%:*}; REPLY=${REPLY#${REPLY%%:*}:}
        local codec_args=${REPLY%%:*}; REPLY=${REPLY#${REPLY%%:*}:}

    	if [[ $prm == '-' ]]; then
            if [[ -n $codec_prms ]]; then
                prm=$codec_prms
            else
                error_exit "rate parameter '--prms' not set"
            fi
        fi
		local qp=- bitrate=-
		[[ $prm -lt 60 ]] && qp=$prm || bitrate=$prm

        local preset=$codec_preset
        local threads=$codec_threads

		local srcRes= srcFps= srcNumFr=
		detect_resolution_string $DIR_VEC/$src; srcRes=$REPLY
		detect_framerate_string $DIR_VEC/$src; srcFps=$REPLY
		detect_frame_num $DIR_VEC/$src $srcRes; srcNumFr=$REPLY

		local args="--res $srcRes --fps $srcFps --threads $threads"
		[[ '-' == $bitrate ]] || args="$args --bitrate $bitrate"
		[[ '-' == $qp      ]] || args="$args --qp $qp"
		[[ '-' == $preset  ]] || args="$args --preset $preset"

		local encExe= encFmt= encExeHash= encCmdArgs= encCmdHash=
		codec_exe $codecId $target; encExe=$REPLY
		codec_fmt $codecId; encFmt=$REPLY
		codec_hash $codecId $target; encExeHash=$REPLY
		codec_cmdArgs $codecId $args; encCmdArgs=$REPLY
		[[ -z "$codec_args" ]] || encCmdArgs="$encCmdArgs $codec_args"

		local SRC=${src//\\/}; SRC=${SRC##*[/\\]} # basename only
		local dst=$SRC.$encFmt

		local info="src:$src codecId:$codecId srcRes:$srcRes srcFps:$srcFps srcNumFr:$srcNumFr"
		info="$info QP:$qp BR:$bitrate PRESET:$preset TH:$threads SRC:$SRC dst:$dst"
		info="$info encExe:$encExe encFmt:$encFmt encExeHash:$encExeHash encCmdArgs:$encCmdArgs"
        REPLY=$info
    }

	local prm= src= codecId= infoTmpFile=$(mktemp)
	for prm in $PRMS; do
    	for src in $VECTORS; do
            codecopt_init "$CODECS" "$PRESET" "$THREADS" "$EXTRA"
            while codecopt_next; do
                local CODEC_LONG=$REPLY
                local info
                prepare_options "$CODEC_LONG" $prm $src >&2; info=$REPLY
        		printf '%s\n' "$info"
        	done
    	done
	done > $infoTmpFile

	local hashTmpFile=$(mktemp)
	while read data; do
		local encCmdArgs src
		dict_getValueEOL "$data" encCmdArgs; encCmdArgs=$REPLY
		dict_getValue "$data" src; src=$REPLY
		local args=${encCmdArgs// /}   # remove all whitespaces
		echo "$src $args"
	done < $infoTmpFile | python $(ospath $dirScript)/md5sum.py | tr -d $'\r' > $hashTmpFile

	local data encCmdHash
	while IFS= read -u3 -r encCmdHash && IFS= read -u4 -r data; do 
  		printf 'encCmdHash:%s %s\n' "$encCmdHash" "$data"
	done 3<$hashTmpFile 4<$infoTmpFile > $optionsFile
	rm $infoTmpFile $hashTmpFile
}

execute_plan()
{
	local testplan=$1; shift
    local dirTmp=$1; shift
	local ncpu=$1; shift
	$dirScript/rpte2.sh $testplan -p $dirTmp -j $ncpu
}

PROGRESS_STAGE_TOTAL=
PROGRESS_STAGE_IDX=
PROGRESS_START_SEC=
PROGRESS_PREV_SEC=
PROGRESS_HDR=
PROGRESS_INFO=
PROGRESS_CNT_TOT=0
PROGRESS_CNT=0
progress_init()
{
    PROGRESS_STAGE_TOTAL=$1
    PROGRESS_STAGE_IDX=1
}
progress_begin()
{
	local name="[$PROGRESS_STAGE_IDX/$PROGRESS_STAGE_TOTAL] $1"; shift
	local str=
	PROGRESS_START_SEC=$SECONDS
    PROGRESS_PREV_SEC=$PROGRESS_START_SEC
	PROGRESS_HDR=
	PROGRESS_INFO=
	PROGRESS_CNT_TOT=1
	PROGRESS_CNT=0

	for str; do
		list_size "$1"; PROGRESS_CNT_TOT=$(( PROGRESS_CNT_TOT * REPLY))
		shift
	done
	print_console "$name\n"

	if [[ $PROGRESS_CNT_TOT != 0 ]]; then
		printf 	-v str "%8s %4s %-11s %11s %5s %2s %6s" "Time" $PROGRESS_CNT_TOT codecId resolution '#frm' QP BR 
		printf 	-v str "%s %9s %2s %-16s %-8s %s" "$str" PRESET TH CMD-HASH ENC-HASH SRC
		PROGRESS_HDR=$str
	fi
}
progress_next()
{
	local outputDirRel=$1; shift
	local outputDir=$DIR_OUT/$outputDirRel info=

	PROGRESS_CNT=$(( PROGRESS_CNT + 1 ))

    [[ $PROGRESS_CNT != $PROGRESS_CNT_TOT && $(( SECONDS - PROGRESS_PREV_SEC )) -lt 1 ]] && return

    { read -r info; } < $outputDir/info.kw

	if [[ -n "$PROGRESS_HDR" ]]; then
		print_console "$PROGRESS_HDR\n"
		PROGRESS_HDR=
	fi

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
	printf 	-v str "%4s %-11s %11s %5s %2s %6s" 	"$PROGRESS_CNT" "$codecId" "${srcRes}@${srcFps}" "$srcNumFr" "$QP" "$BR"
	printf 	-v str "%s %9s %2s %-16s %-8s %s"    "$str" "$PRESET" "$TH" "$HASH" "$ENC" "$SRC"
	PROGRESS_INFO=$str # backup

	local duration=$(( SECONDS - PROGRESS_START_SEC ))
	duration=$(date +%H:%M:%S -u -d @${duration})

	print_console "$duration $PROGRESS_INFO\r"

    PROGRESS_PREV_SEC=$SECONDS
}
progress_end()
{
	if [[ $PROGRESS_CNT != 0 ]]; then
        local duration=$(( SECONDS - PROGRESS_START_SEC ))
        duration=$(date +%H:%M:%S -u -d @${duration})

        print_console "$duration $PROGRESS_INFO\n"
    fi
	PROGRESS_CNT_TOT=0
    PROGRESS_STAGE_IDX=$((PROGRESS_STAGE_IDX+1))
}

output_header()
{
	local str=
	printf 	-v str    "%6s %8s %5s %5s"                extFPS intFPS cpu% kbps
	printf 	-v str "%s %3s %7s %6s %4s"         "$str" '#I' avg-I avg-P peak 
	printf 	-v str "%s %6s %6s %6s %6s"         "$str" gPSNR psnr-I psnr-P gSSIM
	printf 	-v str "%s %-11s %11s %5s %2s %6s"	"$str" codecId resolution '#frm' QP BR 
	printf 	-v str "%s %9s %2s %-16s %-8s"      "$str" PRESET TH CMD-HASH ENC-HASH
	printf 	-v str "%s %5s %5s %5s"             "$str" I% P% Skip%
	printf 	-v str "%s %s"                      "$str" SRC

	echo "$str"
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
		I-%        - % of INTRA blocks in P/B slices
		P-%        - % of INTER blocks in P/B slices
		S-%        - % of skip blocks (skipFlag == 1) in P/B slices
	EOT
	)

#	echo "$str" > /dev/tty
}
output_report()
{
    local report=$1; shift
    local report_kw=$1; shift
	local dict=$1

	echo "$dict" >> $report_kw

	local extFPS= intFPS= cpu= kbps= numI= avgI= avgP= peak= gPSNR= psnrI= psnrP= gSSIM=
	local codecId= srcRes= srcFps= numFr= QP= BR= PRESET= TH= SRC= HASH= ENC=
	local numIntra= numInter= numSkip=

	dict_getValue "$dict" extFPS                ; extFPS=$REPLY
	dict_getValue "$dict" intFPS     '' %8.3f   ; intFPS=$REPLY
	dict_getValue "$dict" cpu                   ; cpu=$REPLY
	dict_getValue "$dict" kbps       '' %5.0f   ; kbps=$REPLY
	dict_getValue "$dict" numI       -  %3d     ; numI=$REPLY
	dict_getValue "$dict" avgI       -  %7.0f   ; avgI=$REPLY
	dict_getValue "$dict" avgP       -  %6.0f   ; avgP=$REPLY
	dict_getValue "$dict" peak       -  %4.1f   ; peak=$REPLY
	dict_getValue "$dict" gPSNR      '' %6.2f   ; gPSNR=$REPLY
	dict_getValue "$dict" psnrI      -  %6.2f   ; psnrI=$REPLY
	dict_getValue "$dict" psnrP      -  %6.2f   ; psnrP=$REPLY
	dict_getValue "$dict" gSSIM      '' %6.3f   ; gSSIM=$REPLY
	dict_getValue "$dict" codecId               ; codecId=$REPLY
	dict_getValue "$dict" srcRes                ; srcRes=$REPLY
	dict_getValue "$dict" srcFps                ; srcFps=$REPLY
	dict_getValue "$dict" srcNumFr              ; srcNumFr=$REPLY
	dict_getValue "$dict" QP                    ; QP=$REPLY
	dict_getValue "$dict" BR                    ; BR=$REPLY
	dict_getValue "$dict" PRESET                ; PRESET=$REPLY
	dict_getValue "$dict" TH                    ; TH=$REPLY
	dict_getValue "$dict" SRC                   ; SRC=$REPLY
	dict_getValue "$dict" encCmdHash            ; HASH=$REPLY; HASH=${HASH::16}
	dict_getValue "$dict" encExeHash            ; ENC=$REPLY ; ENC=${ENC##*_}
	dict_getValue "$dict" numIntra   -  %5.1f   ; numIntra=$REPLY
	dict_getValue "$dict" numInter   -  %5.1f   ; numInter=$REPLY
	dict_getValue "$dict" numSkip    -  %5.1f   ; numSkip=$REPLY

	local str=
	printf 	-v str    "%6s %8s %5s %5s"                "$extFPS" "$intFPS" "$cpu" "$kbps"
	printf 	-v str "%s %3s %7s %6s %4s"         "$str" "$numI" "$avgI" "$avgP" "$peak"
	printf 	-v str "%s %6s %6s %6s %6s"         "$str" "$gPSNR" "$psnrI" "$psnrP" "$gSSIM"
	printf 	-v str "%s %-11s %11s %5s %2s %6s"	"$str" "$codecId" "${srcRes}@${srcFps}" "$srcNumFr" "$QP" "$BR"
	printf 	-v str "%s %9s %2s %-16s %-8s"      "$str" "$PRESET" "$TH" "$HASH" "$ENC"
	printf 	-v str "%s %5s %5s %5s"             "$str" "$numIntra" "$numInter" "$numSkip"
	printf 	-v str "%s %s"                      "$str" "$SRC"

	echo "$str" >> $report
}

report_single_file()
{
    local report=$1; shift
    local report_kw=$1; shift
	local outputDirRel=$1; shift
	local outputDir=$DIR_OUT/$outputDirRel

	local info= dict=
    { read -r info; } < $outputDir/info.kw
    { read -r dict; } < $outputDir/report.kw

	output_report $report $report_kw "$info $dict"
}

encdec_single_file()
{
	local transport=$1; shift
	local outputDirRel=$1; shift
	local outputDir=$DIR_OUT/$outputDirRel
	pushd $outputDir

	local info= encCmdArgs= codecId= src= dst= encCmdSrc= encCmdDst= srcNumFr= encFmt= srcRes=
    { read -r info; } < info.kw

	dict_getValueEOL "$info" encCmdArgs; encCmdArgs=$REPLY
	dict_getValue "$info" codecId; codecId=$REPLY
	dict_getValue "$info" encExe; encExe=$REPLY
	dict_getValue "$info" src; src=$REPLY
	dict_getValue "$info" dst; dst=$REPLY
	dict_getValue "$info" srcNumFr; srcNumFr=$REPLY
	dict_getValue "$info" encFmt; encFmt=$REPLY
	dict_getValue "$info" srcRes; srcRes=$REPLY

    local remoteExe= remoteSrc=
	if [[ $transport == local ]]; then
        remoteExe=$DIR_BIN/$encExe
        remoteSrc=$DIR_VEC/$src
	elif [[ $transport == condor ]]; then
        remoteExe=$DIR_BIN/$encExe
    	if [[ -z ${CONDOR_VECTORS:-} ]]; then
            remoteSrc=$(basename $src)
            src=$DIR_VEC/$src
            # replace transfer with 'nut'
            [[ -f ${src%.*}.nut ]] && src=${src%.*}.nut
        else
            remoteSrc=$CONDOR_VECTORS/$src
            src= # do not transfer
        fi
    else
        error_exit "encoding+decoding with transport=$transport not implemented" >&2
	fi

	codec_cmdSrc $codecId $remoteSrc; encCmdSrc=$REPLY
	codec_cmdDst $codecId $dst; encCmdDst=$REPLY

	# temporary hack, for backward compatibility (remove later)
	[[ $codecId == h265demo ]] && encCmdArgs="-c h265demo.cfg $encCmdArgs"

	local args="$encCmdArgs $encCmdSrc $encCmdDst"
	echo "$args" > input_args # memorize
	echo "$remoteExe" > input_exe # memorize

    # Enc
    export codecId=$codecId
    export encoderExe=$remoteExe
    export encoderArgs=$args
    export bitstreamFile=$dst
    export monitorCpu=$ENABLE_CPU_MONITOR
    # Dec
    export originalYUV=$remoteSrc
    export bitstreamFile=$dst
    export bitstreamFmt=$encFmt
    export resolutionWxH=$srcRes
    export TRACE_HM=$TRACE_HM

	if [[ $transport == local ]]; then

        . $dirScript/executor.sh

        executor encdec

	elif [[ $transport == condor ]]; then

        local executable=$dirScript/executor.sh
        local arguments=encdec
        local transfer="$src,$encoderExe"
        local environment="codecId=$codecId;encoderExe=$(basename $encoderExe);encoderArgs=$encoderArgs;bitstreamFile=$bitstreamFile;monitorCpu=$monitorCpu"
        environment="$environment;originalYUV=$originalYUV;bitstreamFile=$bitstreamFile;bitstreamFmt=$bitstreamFmt;resolutionWxH=$resolutionWxH;TRACE_HM=$TRACE_HM"
        # not available on a remote machine
        case $encFmt in h266) transfer="$transfer,$DIR_BIN/vvdecapp";; esac

		CONDOR_makeTask "$executable" "$arguments" "$transfer" "$environment" encdec > encdec_condor.sub
		CONDOR_submit encdec_condor.sub
    else
        error_exit "encoding+decoding with transport=$transport not implemented" >&2
	fi

	popd
}

encode_single_file()
{
	local transport=$1; shift
	local outputDirRel=$1; shift
	local outputDir=$DIR_OUT/$outputDirRel
	pushd $outputDir

	local info= encCmdArgs= codecId= src= dst= encCmdSrc= encCmdDst= srcNumFr=
    { read -r info; } < info.kw

	dict_getValueEOL "$info" encCmdArgs; encCmdArgs=$REPLY
	dict_getValue "$info" codecId; codecId=$REPLY
	dict_getValue "$info" encExe; encExe=$REPLY
	dict_getValue "$info" src; src=$REPLY
	dict_getValue "$info" dst; dst=$REPLY
	dict_getValue "$info" srcNumFr; srcNumFr=$REPLY

    local remoteExe= remoteSrc=
	if [[ $transport == local ]]; then
        remoteExe=$DIR_BIN/$encExe
        remoteSrc=$DIR_VEC/$src
	elif [[ $transport == condor ]]; then
        remoteExe=$DIR_BIN/$encExe
    	if [[ -z ${CONDOR_VECTORS:-} ]]; then
            remoteSrc=$(basename $src)
            src=$DIR_VEC/$src
        else
            remoteSrc=$CONDOR_VECTORS/$src
            src= # do not transfer
        fi
	elif [[ $transport == adb || $transport == ssh ]]; then
		local remoteDirBin= remoteDirVec=
		TARGET_getExecDir; remoteDirBin=$REPLY/vctest/bin
		TARGET_getDataDir; remoteDirVec=$REPLY/vctest/vectors
		remoteExe=$remoteDirBin/$encExe
		remoteSrc=$remoteDirVec/$src
    else
        error_exit "encoding with transport=$transport not implemented" >&2
	fi

	codec_cmdSrc $codecId $remoteSrc; encCmdSrc=$REPLY
	codec_cmdDst $codecId $dst; encCmdDst=$REPLY

	# temporary hack, for backward compatibility (remove later)
	[[ $codecId == h265demo ]] && encCmdArgs="-c h265demo.cfg $encCmdArgs"

	local args="$encCmdArgs $encCmdSrc $encCmdDst"
	echo "$args" > input_args # memorize
	echo "$remoteExe" > input_exe # memorize

    export codecId=$codecId
    export encoderExe=$remoteExe
    export encoderArgs=$args
    export bitstreamFile=$dst
    export monitorCpu=$ENABLE_CPU_MONITOR

	if [[ $transport == local ]]; then

        . $dirScript/executor.sh

        executor encode

	elif [[ $transport == condor ]]; then

        local executable=$dirScript/executor.sh
        local arguments=encode
        local transfer="$src,$encoderExe"
        local environment="codecId=$codecId;encoderExe=$(basename $encoderExe);encoderArgs=$encoderArgs;bitstreamFile=$bitstreamFile;monitorCpu=$monitorCpu"

		CONDOR_makeTask "$executable" "$arguments" "$transfer" "$environment" encoded > encoded_condor.sub
		CONDOR_submit encoded_condor.sub

	elif [[ $transport == adb || $transport == ssh ]]; then
		local remoteDirOut remoteOutputDir
		TARGET_getDataDir; remoteDirOut=$REPLY/vctest/out
		remoteOutputDir=$remoteDirOut/$outputDirRel

		local remoteDirBin remoteDirCore
		TARGET_getExecDir; remoteDirBin=$REPLY/vctest/bin remoteDirCore=$REPLY/vctest/core
		TARGET_exec "
            export codecId=$codecId
            export encoderExe=$encoderExe
            export encoderArgs=\"$encoderArgs\"
            export bitstreamFile=$bitstreamFile
            export monitorCpu=$monitorCpu
			rm -rf $remoteOutputDir && mkdir -p $remoteOutputDir && cd $remoteOutputDir
            $remoteDirCore/executor.sh encode
        "
		TARGET_pull $remoteOutputDir/. .
		TARGET_exec "rm -rf $remoteOutputDir"
    else
        error_exit "encoding with transport=$transport not implemented" >&2
	fi

	popd
}

decode_single_file()
{
	local transport=$1; shift
	local outputDirRel=$1; shift
	local outputDir=$DIR_OUT/$outputDirRel
	pushd $outputDir

	local info= src= dst=
    { read -r info; } < info.kw

	dict_getValue "$info" src; src=$REPLY
	dict_getValue "$info" dst; dst=$REPLY

	local encFmt= srcRes=
	dict_getValue "$info" encFmt; encFmt=$REPLY
	dict_getValue "$info" srcRes; srcRes=$REPLY

    local remoteSrc
    if [[ $transport == condor ]]; then
    	if [[ -z "${CONDOR_VECTORS:-}" ]]; then
            remoteSrc=$(basename "$src")
            src=$DIR_VEC/$src
        else
            remoteSrc=$CONDOR_VECTORS/$src
            src= # do not transfer
        fi
    else
        remoteSrc=$DIR_VEC/$src
    fi

    export originalYUV=$remoteSrc
    export bitstreamFile=$dst
    export bitstreamFmt=$encFmt
    export resolutionWxH=$srcRes
    export TRACE_HM=$TRACE_HM

    if [[ $transport != condor ]]; then # execute locally

        . $dirScript/executor.sh

        executor decode
    else
        local executable=$dirScript/executor.sh
        local arguments=decode
        local transfer="$src,$bitstreamFile"
        local environment="originalYUV=$originalYUV;bitstreamFile=$bitstreamFile;bitstreamFmt=$bitstreamFmt;resolutionWxH=$resolutionWxH;TRACE_HM=$TRACE_HM"

        # not available on a remote machine
        case $encFmt in h266) transfer="$transfer,$DIR_BIN/vvdecapp";; esac

		CONDOR_makeTask "$executable" "$arguments" "$transfer" "$environment" decoded > decoded_condor.sub
		CONDOR_submit decoded_condor.sub
    fi

    popd
}

parse_single_file()
{
	local outputDirRel=$1; shift
	local outputDir=$DIR_OUT/$outputDirRel
	pushd $outputDir

	local info= codecId= srcNumFr= srcFps=
    { read -r info; } < info.kw

	dict_getValue "$info" codecId; codecId=$REPLY
	dict_getValue "$info" srcNumFr; srcNumFr=$REPLY
	dict_getValue "$info" srcFps; srcFps=$REPLY

    local bitstream_size
    { read -r bitstream_size; } < decoded_bitstream_size

    local kbps
	kbps=$(awk "BEGIN { print 8 * $bitstream_size / ($srcNumFr/$srcFps) / 1000 }")

	local cpuAvg=- extFPS=- intFPS=
	if [[ -f encoded_cpu ]]; then # may not exist
		parse_cpuLog encoded_cpu; cpuAvg=$REPLY
		[[ $cpuAvg == '-' ]] || printf -v cpuAvg "%.0f" "$cpuAvg"
	fi
	if [[ -f encoded_sec ]]; then # may not exist
        local consumedSec
        { read -r consumedSec; } < encoded_sec
        [[ $consumedSec -gt 0 ]] && extFPS=$(( srcNumFr / consumedSec ))
	fi
	intFPS=$(parse_stdoutLog $codecId encoded_log $srcNumFr)

	# merge one-liners
	local logsToMerge="decoded_psnr decoded_ssim"
    if [[ -f decoded_ffprobe ]]; then
		{ # dump one liners for each frame from ffprobe output
			local type= size= cnt=0
			while read -r; do
				case $REPLY in
					'[FRAME]')  type=; size=; cnt=$(( cnt + 1 ));;
					'[/FRAME]') echo "n:$cnt type:$type size:$size";;
					pict_type=I) type=I;;
					pict_type=P) type=P;;
					pkt_size=*) size=${REPLY#pkt_size=};;
				esac
			done < decoded_ffprobe
		} > parsed_frame
        logsToMerge="parsed_frame $logsToMerge"
    fi
	paste $logsToMerge | tr -d $'\r' > parsed_summary

    local framestat=
    framestat=$(parse_framestat parsed_summary)

    local blockstat=
	[[ -f decoded_trace_hm ]] && blockstat=$(python $parsePy decoded_trace_hm)

	local dict="extFPS:$extFPS intFPS:$intFPS cpu:$cpuAvg kbps:$kbps $framestat $blockstat"
	echo "$dict" > report.kw

	date "+%Y.%m.%d-%H.%M.%S" > parsed.ts

	popd
}

parse_framestat()
{
	local summaryLog=$1; shift
	local summary=

    local script='
        function get_value(name,           a, b) {
            split ($0, a, name);
            split (a[2], b);
            return b[1];
        }
    	function countGlobalPSNR(psnr_y, psnr_u, psnr_v) {
            return ( 6*psnr_y + psnr_u + psnr_v ) / 8;
	    }
	    function x265_ssim2dB(ssim) {
			return (1 - ssim) <= 0.0000000001 ? 100 : -10*log(1 - ssim)/log(10)
	    }
	    function setDefault(x) {
			return length(x) == 0 ? "-" : x
	    }

        BEGIN {
        } 
           
        {
            psnr_y = get_value("psnr_y:");
            psnr_u = get_value("psnr_u:");
            psnr_v = get_value("psnr_v:");
            ssim = get_value("Y:");
            size = get_value("size:");
        }
        {
                   num++;  psnr_y_avg  += psnr_y; psnr_u_avg  += psnr_u; psnr_v_avg  += psnr_v; ssim_avg  += ssim;
        }

        /type:I/ { numI++; psnr_y_avgI += psnr_y; psnr_u_avgI += psnr_u; psnr_v_avgI += psnr_v; ssim_avgI += ssim; sizeI += size; }
        /type:P/ { numP++; psnr_y_avgP += psnr_y; psnr_u_avgP += psnr_u; psnr_v_avgP += psnr_v; ssim_avgP += ssim; sizeP += size; }
        END {
            if( num > 0 ) {
                psnr_y_avg  /= num;  psnr_u_avg  /= num;  psnr_v_avg  /= num;  ssim_avg  /= num;
            }

            if( numI > 0 ) {
                psnr_y_avgI /= numI; psnr_u_avgI /= numI; psnr_v_avgI /= numI; ssim_avgI /= numI; avgI = sizeI/numI;
            }
            if( numP > 0 ) {
                psnr_y_avgP /= numP; psnr_u_avgP /= numP; psnr_v_avgP /= numP; ssim_avgP /= numP; avgP = sizeP/numP;
            }

            gPSNR = countGlobalPSNR(psnr_y_avg,  psnr_u_avg,  psnr_v_avg );  gSSIM = ssim_avg
            psnrI = countGlobalPSNR(psnr_y_avgI, psnr_u_avgI, psnr_v_avgI);  ssimI = ssim_avgI
            psnrP = countGlobalPSNR(psnr_y_avgP, psnr_u_avgP, psnr_v_avgP);  ssimP = ssim_avgP
            peak = avgP > 0 ? avgI/avgP : 0;

            gSSIM_db=x265_ssim2dB(gSSIM)

            numI = setDefault(numI)
            numP = setDefault(numP)
            sizeI = setDefault(sizeI)
            sizeP = setDefault(sizeP)
            avgI = setDefault(avgI)
            avgP = setDefault(avgP)
            ssimI = setDefault(ssimI)
            ssimP = setDefault(ssimP)

            print "numI:"numI" numP:"numP" sizeI:"sizeI" sizeP:"sizeP\
                 " avgI:"avgI" avgP:"avgP" peak:"peak\
                 " psnrI:"psnrI" psnrP:"psnrP" gPSNR:"gPSNR\
                 " ssimI:"ssimI" ssimP:"ssimP" gSSIM:"gSSIM_db\
                 " gSSIM_db:"gSSIM_db" gSSIM_en:"gSSIM
        }
    '
    summary=$(awk "$script" "$summaryLog")

    echo "$summary"
}

parse_cpuLog()
{
    local log=$1 endtime cpu=-
    if endtime=$(grep '^[0-9]\+ (cat)' $log | tail -n1 | awk '{ print $22 }'); then
        if ! cpu=$(grep -v '(cat)' $log | grep '^[0-9]\+ (.*)' | tail -n1 | \
                    awk -v endtime=$endtime '{ print endtime != $22 ? 100*( $14 + $15 )/( endtime - $22 ) : 0 }'); then
            cpu=-
        fi
    fi
    REPLY=$cpu
}

parse_stdoutLog()
{
	local codecId=$1; shift
	local log=$1; shift
    local numFrames=$1; shift
	local fps= snr=
	case $codecId in
		ashevc)
			fps=$(grep -i ' fps)'           $log | tr -s ' ' | cut -d' ' -f 6); fps=${fps#(}
		;;
		x265)
			fps=$(grep -i ' fps)'           $log | tr -s ' ' | cut -d' ' -f 6); fps=${fps#(}
		;;
		kvazaar)
			fps=$(grep -i ' FPS:'           $log | tr -s ' ' | cut -d' ' -f 3)
		;;
		kingsoft)
			fps=$(grep -i 'test time: '     $log | tr -s ' ' | cut -d' ' -f 8)
			#fps=$(grep -i 'pure encoding time:' $log | head -n 1 | tr -s ' ' | cut -d' ' -f 8)
		;;
		ks)
			fps=$(grep -i 'FPS: '           $log | tr -s ' ' | cut -d' ' -f 2)
		;;
		intel_*)
			fps=$(grep -i 'Encoding fps:'   $log | tr -s ' ' | cut -d' ' -f 3)
		;;
		h265demo)
			fps=$(grep -i 'TotalFps:'       $log | tr -s ' ' | cut -d' ' -f 5)
		;;
		h265demo_v2)
			fps=$(grep -i 'Encode speed:'   $log | tr -s ' ' | cut -d' ' -f 9)
			fps=${fps%%fps}
        ;;
		h265demo_v3)
            fps=$(grep -i 'Encode pure speed:'   $log | tr -s ' ' | cut -d' ' -f 4)
			[[ -z "$fps" ]] && fps=$(grep -i 'Encode speed:'   $log | tr -s ' ' | cut -d' ' -f 9)
			fps=${fps%%fps*}
		;;
		h264demo)
			fps=$(grep -i 'Tests completed' $log | tr -s ' ' | cut -d' ' -f 1)
		;;
		h264aspt)
			fps=$(grep -i 'fps$' $log | tr -s ' ' | cut -d' ' -f 3)
		;;
		vp8|vp9) # be carefull with multipass
            fps=$(cat $log | tr "\r" "\n" | grep -E '\([0-9]{1,}\.[0-9]{1,} fps\)' | tail -n 1 | tr -d '()' | tr -s ' ' | cut -d' ' -f 10)
		;;
		vvenc*)
            case $codecId in
                vvencff*)
                    local sec
                    sec=$(cat $log | grep -i 'Total Time: ' | tr -s ' ' | cut -d' ' -f 4)
                    fps=$(echo "" | awk "{ print $numFrames / $sec }")
                ;;
                *)
        			fps=$(grep -i 'Total Time: '     $log | tr -s ' ' | cut -d' ' -f 6)
		        ;;
            esac
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
