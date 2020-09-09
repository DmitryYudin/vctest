set -eu -o pipefail

#
# TODO: Evaluation bdrate for psnr-I.P looks suspicious since we use total bitrate, not a budget consumed by I/P
# TODO: Add avgPSNR-Y/U/V to output statistics
#
dirScript=$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )
. "$dirScript/utility_functions.sh"

readonly dirScript=$(cygpath -m "$dirScript")
readonly bdratePy=$(ospath "$dirScript")/bdrate/bdrate.py
readonly KEY_DELIM="\(^\| \)" # line start or space

REF_CODEC=
INPUT_LOG=
KEYS=

usage()
{
	cat	<<-EOF
	Usage:
	    $(basename $0) [opt]

	Options:
	    -h|--help     Print help.
	    -i|--input    Input key/value log file to parse. Line with 'codecId:' are only considered.
	    -k|--key      Key to use for BD-rate evaluation: gPSNR, psnrI, ... (default: gPSNR)
	    -c|--codec    Reference codecId (default: first found)

	Example:
	    $(basename $0) -c x265 -i report_k2.kw
	EOF
}

entrypoint()
{
	[[ "$#" -eq 0 ]] && usage && echo "error: arguments required" >&2 && return 1

	while [[ "$#" -gt 0 ]]; do
		case $1 in
			-h|--help)		usage && return;;
			-i|--input)     INPUT_LOG=$2;;
			-k|--key)       KEYS="$KEYS $2";;
			-c|--codec) 	REF_CODEC=$2;;
			*) error_exit "unrecognized option '$1'"
		esac
		shift 2
	done
	[[ -z "$INPUT_LOG" ]] && error_exit "input log file not set"
	[[ -z "$KEYS" ]] && KEYS=gPSNR

	local codec= codecs=
	{
		codecs=$(
			cat "$INPUT_LOG" | grep -i "${KEY_DELIM}codecId:" | while read -r; do dict_getValue "$REPLY" codecId; echo "$REPLY"; done \
				| sort -u --ignore-leading-blanks --ignore-case | tr $'\n' ' '
		)
		[[ -z "$codecs" ]] && error_exit "no codecs found"
		if [[ -z "$REF_CODEC" ]]; then
			for REF_CODEC in $codecs; do
				break			
			done
			echo "warning: refCodec not set, select first from log '$REF_CODEC'" >&2
		fi

		local codec= found=
		for codec in $codecs; do
			[[ $codec == "$REF_CODEC" ]] && found=1
		done
		[[ -z "found" ]] && error_exit "$REF_CODEC not found in codecs list: $codecs"
	}

	local src= vectors=
	{
		vectors=$(
			cat "$INPUT_LOG" | grep -i "${KEY_DELIM}codecId:" | while read -r; do dict_getValue "$REPLY" SRC; echo "$REPLY"; done \
				| sort -u --ignore-leading-blanks --ignore-case | tr $'\n' ' '
		)
	}
	echo "codecs: $codecs" > /dev/tty
	echo "vectors: $vectors" > /dev/tty

	for codec in $codecs; do
	for src in $vectors; do
		local report=
		for key in $KEYS; do
			local refData= tstData=
			{
				refData=$(
					cat "$INPUT_LOG" | grep -i "${KEY_DELIM}codecId:$REF_CODEC[ $]" | grep -i "${KEY_DELIM}SRC:$src[ $]" | \
						while read -r; do 
							dict=$REPLY
							dict_getValue "$dict" kbps; kbps=$REPLY
							dict_getValue "$dict" $key; psnr=$REPLY
							echo "--ref $kbps,$psnr"
						done | \
						tr $'\n' ' '
				)
			}
	    
			[[ $codec == "$REF_CODEC" ]] && continue
			tstData=$(
				cat "$INPUT_LOG" | grep -i "${KEY_DELIM}codecId:$codec[ $]" | grep -i "${KEY_DELIM}SRC:$src[ $]" | \
					while read -r; do 
						dict=$REPLY
						dict_getValue "$dict" kbps; kbps=$REPLY
						dict_getValue "$dict" $key; psnr=$REPLY
						echo "--tst $kbps,$psnr"
					done | \
					tr $'\n' ' '
			)
			local result= bdRate= bdPSNR=
			result=$(python $bdratePy $refData $tstData)
			dict_getValue "$result" BD-rate; bdRate=$REPLY
			dict_getValue "$result" BD-PSNR; bdPSNR=$REPLY
			printf -v report "%s BD-rate($key):%-6.2f BD-PSNR($key):%-6.2f" "$report" "$bdRate" "$bdPSNR"
		done
		report=${report# }
        local res=
        detect_resolution_string "$src"; res=$REPLY
		if [[ -n "$report" ]]; then
			printf "ref:%-13s tst:%-13s %-9s $report SRC:%s\n" "$REF_CODEC" "$codec" "$res" "$src"
		fi
	done
	done
}


entrypoint "$@"
