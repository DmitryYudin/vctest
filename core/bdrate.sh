set -eu -o pipefail

dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )

. "$dirScript/utility_functions.sh"
. "$dirScript/codec.sh"

readonly timestamp=$(date "+%Y.%m.%d-%H.%M.%S")

REPORT=bdrate.log
REPDIR=report
KEY=gPSNR

usage()
{
	cat	<<-EOF
	Usage:
	    $(basename $0) [opt]

	Options:
	    -h|--help        Print help.
	    -o|--output  <x> Report path. Default: "$REPORT".
	    -r|--repdir  <x> Performance report directory for 'testbench.sh'. Default: "$REPDIR".
	    -k|--key     <x> Quality metric for BD-rate metric evaluation: gPSNR, gSSIM ...
	    -c|--codec   <x> Codecs list. First item considered as the reference.

	    Options different from above go to 'testbench.sh' script unchanged and applied to
	    every codec run: -i -p --adb --ssh...

	    Individual (per codec) parameters can be set with '-c' option

	    Exactly 4 parameters for '-p' option must be set to evaluate bd-rate scores.
    
	Example:
	    $(basename $0) -i vec_720p_30fps.yuv -p'22 27 32 37' -c kingsoft -c 'kingsoft --preset ultrafast' 
	    $(basename $0) -i vec_720p_30fps.yuv -p'700 1000 1400 2000' -c 'kingsoft x265 h265demo' 

	EOF
}

entrypoint()
{
	[[ "$#" -eq 0 ]] && usage && echo "error: arguments required" >&2 && return 1

	local cmd_vec= cmd_codecs= cmd_report=$REPORT cmd_repdir=$REPDIR cmd_key=$KEY
    local prev=
	for arg do
		case $arg in
			-h|--help) usage; return;;
        esac

		shift
        if [[ -z $prev ]]; then
    		case $arg in
    			-o|--out*) 		prev=$arg;;
    			-r|--repdir)    prev=$arg;;
			    -k|--key)       prev=$arg;;
    			-c|--codec) 	prev=$arg;;
    			*) set -- "$@" "$arg";;
	    	esac            
        else
    		case $prev in
    			-o|--out*) 		cmd_report=$arg;;
    			-r|--rep*) 		cmd_repdir=$arg;;
			    -k|--key)       cmd_key=$arg;;
    			-c|--codec) 	cmd_codecs="$cmd_codecs; $arg";;
	    	esac
            prev=
        fi
	done

    local codecs_long
    preproc_codec_list "$cmd_codecs"; codecs_long=$REPLY

    mkdir -p "$cmd_repdir"

    # Encode (generate logs)
    local codec_long
    local oldIFS=$IFS IFS=';'
    for codec_long in $codecs_long; do
        IFS=$oldIFS
        local codec=${codec_long%% *}
        local prms=${codec_long#$codec}; prms=${prms# }
        local tag
        get_codec_tag "$codec_long"; tag=$REPLY
        local report="${cmd_repdir}/bdrate_${timestamp}_${tag}.log"
        "$dirScript/testbench.sh" -c "$codec" $prms -o "$report" "$@"
    done
    IFS=$oldIFS

    # Filter-out reference codec (first in list)
    local ref_codec_long=${codecs_long%%;*}; codecs_long=${codecs_long#$ref_codec_long;}
    local ref_codec=${ref_codec_long%% *}
    local ref_prms=${ref_codec_long#$ref_codec}; ref_prms=${ref_prms# }
    local ref_tag=    
    get_codec_tag "$ref_codec_long"; ref_tag=$REPLY
    local ref_report="${cmd_repdir}/bdrate_${timestamp}_${ref_tag}.log"
    local ref_kw_log="${ref_report%.*}.kw"

    # Make sure we have valid data
    if ! grep -m 1 'codecId:' "$ref_kw_log" >/dev/null; then
        error_exit "no date for reference codec '$ref_codec_long'"
    fi

    # Calcultate BD-rate
    local info
    get_test_info "$@"; info=$REPLY

    echo "" >> $cmd_report
    local oldIFS=$IFS IFS=';'
    for codec_long in $codecs_long; do
        IFS=$oldIFS
        local codec=${codec_long%% *}
        local prms=${codec_long#$codec}; prms=${prms# }
        local tag
        get_codec_tag "$codec_long"; tag=$REPLY
        local report="${cmd_repdir}/bdrate_${timestamp}_${tag}.log"
        local kw_log="${report%.*}.kw"
        echo "$timestamp ref:$ref_codec[$ref_prms] tst:$codec[$prms] KEY=$KEY [$info]" | tee -a "$cmd_report"
        # Make sure we have valid data
        if ! grep -m 1 'codecId:' "$kw_log" > /dev/null ; then
            echo "no data, skip" | tee -a "$cmd_report"
            continue;
        fi
        "$dirScript/bdrate/bdrate.sh" -i "$ref_kw_log" -i "$kw_log" | tee -a "$cmd_report"
    done
    IFS=$oldIFS
}

get_codec_tag()
{
    local codec_long=$1; shift
    local codec=${codec_long%% *}
    local prms=${codec_long#$codec}
    prms=${prms# }
    [[ -n "$prms" ]] &&  prms="$(echo "$prms" | tr ' ' '_')"
    REPLY="$codec${prms:+[$prms]}"
}

preproc_codec_list()
{
    local codecs=$1; shift

    # shrink spaces
    codecs=$(echo "$codecs" | tr -s "[:space:]")

    local known_codecs
    codec_get_knownId; known_codecs=$REPLY

    # remove possible delimiters
    codecs=$(echo "$codecs" | tr -d ';')

    # preppend codecId with delimiter
    local token known_codec retval=
    for token in $codecs; do
        local found=false
        for known_codec in $known_codecs; do
            [[ $token == $known_codec ]] && found=true
        done
        $found && retval="$retval;$token" || retval="$retval $token";
    done
    retval=${retval#;}
    codecs=$retval

    # remove duplicates and extra spaces
    local oldIFS=$IFS IFS=';' token retval=
    for token in $codecs; do
        IFS=$oldIFS
        local x="$token" unique= found=false
        x=${x#"${x%%[! $'\t']*}"}; x=${x%"${x##*[! $'\t']}"}
        for unique in $retval; do
            [[ $x == $unique ]] && found=true && break
        done
        $found && continue
        retval="$retval;$x"
    done
    IFS=$oldIFS
   	retval=${retval#;}
    REPLY=$retval
}

get_test_info()
{
    # filter all, but '-i' option from input list
    local prev=
	for arg do
		shift
        if [[ -z $prev ]]; then
    		case $arg in
    			-i|--in*) 		prev=$arg;;
    			*) set -- "$@" "$arg";;
	    	esac            
        else
            prev=
        fi
	done
    REPLY=$(echo "$*" | tr -s "[:space:]")
}

entrypoint "$@"
