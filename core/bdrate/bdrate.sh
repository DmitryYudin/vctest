set -eu -o pipefail

#
# TODO: Evaluation bdrate for psnr-I.P looks suspicious since we use total bitrate, not a budget consumed by I/P
# TODO: Add avgPSNR-Y/U/V to output statistics
#
dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
. "$dirScript/../utility_functions.sh"

readonly dirScript=$(ospath "$dirScript")
readonly bdratePy=$(ospath "$dirScript")/bdrate.py

usage()
{
	cat	<<-EOF
	Usage:
	    $(basename $0) [opt]

	Options:
	    -h|--help     Print help.
	    -i|--input    Input key/value log file to parse. Line with 'codecId:' are only considered.
	    -k|--key      Key to use for BD-rate evaluation: gPSNR, psnrI, ... (default: gPSNR)

	Example:
	    $(basename $0) -i report_ref.kw -i report_tst.kw
	EOF
}

entrypoint()
{
    local REF_LOG= TST_LOG= KEY=gPSNR # =gSSIM

    [[ "$#" -eq 0 ]] && usage && echo "error: arguments required" >&2 && return 1
    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -h|--help)      usage && return;;
            -i|--input)     if [[ -z "$REF_LOG" ]]; then
                                REF_LOG=$2
                            elif [[ -z "$TST_LOG" ]]; then
                                TST_LOG=$2
                            else
                                error_exit "too many '$1' options"
                            fi
            ;;
            -k|--key)       KEY=$2;;
            *) error_exit "unrecognized option '$1'"
        esac
        shift 2
    done
    [[ -z "$REF_LOG" ]] && error_exit "reference log file not set"
    [[ -z "$TST_LOG" ]] && error_exit "under test log file not set"

    local ref_data= tst_data=
    ref_data=$(grep 'codecId:' "$REF_LOG" || true)
    tst_data=$(grep 'codecId:' "$TST_LOG" || true)

    local vectors
    read_vectors "$ref_data" "$tst_data"; vectors=$REPLY

    printf " %7s %7s %-11s %s\n" "BD-rate" "BD-PSNR" "resolution" "SRC"

    local src
    for src in $vectors; do
        local refpoints
        read_refpoints "$src" "$KEY" "$ref_data" "$tst_data"; refpoints=$REPLY

        local result= bdRate= bdPSNR= srcRes= srcFps=
        result=$(python $bdratePy $refpoints)
        dict_getValue "$result" BD-rate; bdRate=$REPLY
        dict_getValue "$result" BD-PSNR; bdPSNR=$REPLY

        detect_resolution_string "$src"; srcRes=$REPLY
        detect_framerate_string "$src"; srcFps=$REPLY
        printf " %7.2f %7.2f %-11s %s\n" "$bdRate" "$bdPSNR" "${srcRes}@${srcFps}" "$src"
    done
}

read_refpoints()
{
    filter_src() {
        local src=$1; shift
        local data=$1; shift
        local IFS=$'\n' retval=
        for dict in $data; do
            dict_getValue "$dict" SRC;
            [[ $REPLY != $src ]] && continue
            retval="$retval"$'\n'"$dict"
        done
        retval=${retval# }
        REPLY=$retval
    }
    read_refpoints_internal() {
        local key=$1; shift
        local data=$1; shift
        local IFS=$'\n' retval=
        for dict in $data; do
            local kbps= psnr=
            dict_getValue "$dict" kbps;   kbps=$REPLY
            dict_getValue "$dict" "$key"; psnr=$REPLY
            retval="$retval $kbps,$psnr"
        done
        retval=${retval# }
        REPLY=$retval
    }
    prepend_each_item() {
        local pref=$1; shift
        local data=$1; shift
        local item= retval=
        for item in $data; do
            retval="$retval $pref $item"
        done
        retval=${retval# }
        REPLY=$retval
    }
    local src=$1; shift
    local key=$1; shift
    local ref_data=$1; shift
    local tst_data=$1; shift
    filter_src "$src" "$ref_data"; ref_data=$REPLY
    filter_src "$src" "$tst_data"; tst_data=$REPLY
    local ref_refpoints= tst_refpoints=
    read_refpoints_internal "$key" "$ref_data"; ref_refpoints=$REPLY
    read_refpoints_internal "$key" "$tst_data"; tst_refpoints=$REPLY

    local ref_n= tst_n=
    list_size "$ref_refpoints"; ref_n=$REPLY
    list_size "$tst_refpoints"; tst_n=$REPLY
    [[ $ref_n != 4 ]] && error_exit "$ref_n refpoints found in a reference data, must be 4"
    [[ $tst_n != 4 ]] && error_exit "$tst_n refpoints found in a test data, must be 4"

    prepend_each_item "--ref" "$ref_refpoints"; ref_refpoints=$REPLY
    prepend_each_item "--tst" "$tst_refpoints"; tst_refpoints=$REPLY

    REPLY="$ref_refpoints $tst_refpoints"
}

read_vectors()
{
    read_vectors_internal() {
        local data=$1; shift
        local IFS=$'\n' retval=
        for dict in $data; do
            dict_getValue "$dict" SRC; retval="$retval $REPLY"
        done
        retval=$(echo "$retval" | tr ' ' '\n' | sort -u | tr '\n' ' ')
        retval=${retval# }
        retval=${retval% }
        REPLY=$retval
    }
    local ref_data=$1; shift
    local tst_data=$1; shift
    local ref_vectors= tst_vectors=
    read_vectors_internal "$ref_data"; ref_vectors=$REPLY
    read_vectors_internal "$tst_data"; tst_vectors=$REPLY
    if [[ "$ref_vectors" != "$tst_vectors" ]]; then
        error_exit "different set of reference and test vectors"
    fi
    REPLY=$ref_vectors
}

entrypoint "$@"
