#
# For the sourcing
#
error_exit()
{
	local src="${BASH_SOURCE[1]}"; src=${src//\\//}; src=${src##*/}; src=${src%.*}
	printf "$src:${FUNCNAME[1]}():${BASH_LINENO[0]} error: %s\n" "$*" >&2 
	exit 1
}

cygpath() # just to keep working on *nix
{
	case $OS in 
		*_NT) command cygpath "$@";;
		*) echo "$2";;
	esac
}

dict_getValue()
{
	local dict=$1 key=$2; val=${dict#*$key:};	
	val=${val#"${val%%[! $'\t']*}"} # Remove leading whitespaces 
	val=${val%%[ $'\t']*} # Cut everything after left most whitespace
	REPLY=$val
}

list_size()
{
	local list="$*"
	local cnt=0
	for x in $list; do
		cnt=$((cnt + 1))
	done
	REPLY=$cnt
}

# Works as print not 'echo', i.e. does not insert 'eol' character at the end of string.
# Only takes care about '\n' and '\r' trailing charactrs (i.e. single line output only)
# Does not pretend to cover all use cases (non-printable characters, etc)
print_console()
{
	cut_to_console_width()
	{
		if [ -z "${COLUMNS:-}" ]; then
			case $OS in *_NT) COLUMNS=$(mode.com 'con:' | grep -i Columns: | tr -d ' ' | cut -s -d':' -f2) && export COLUMNS; esac
		fi

		# Note, Windows terminal inserts carriage character after printed string
		# this results in line break if len(str) == NUM_COLUMNS. So we cut to NUM_COLUMNS-1 length
		REPLY=$*
		[ -n "${COLUMNS:-}" ] && [ "${#REPLY}" -ge "${COLUMNS:-}" ] && REPLY="${REPLY:0:$((COLUMNS - 4))}..."

		return 0
	}
	# catch endings we do not want to cut
	local str=$* nl= cr= line_clear=
	str=${str//"\r"/$'\r'}
	str=${str//"\n"/$'\n'}
#	[ "${str: -1}" == $'\r' ] && str=${str%$'\r'} && cr=1
	[ "${str: -1}" == $'\r' ] && str=${str%$'\r'} && cr=1
	[ "${str: -1}" == $'\n' ] && str=${str%$'\n'} && nl=1

	cut_to_console_width "$str"; str=$REPLY

	[ -n "$nl" ] && str="$str"$'\n'
	[ -n "$cr" ] && str="$str"$'\r' && line_clear="\\x1B[2K"
	printf "$line_clear%s" "$str" > /dev/tty
}

detect_resolution_string()
{	
	local filename=$1; shift
	local name=${filename//\\/}; name=${name##*[/\\]}; name=${name%%.*}
	local res=

	# X -> x
	name=${name//X/x}

	# try HxW pattern delimited by "." or "_"
	for delim in _ .; do
		local IFS=$delim
		for i in $name; do
			if [[ "$i" =~ ^[1-9][0-9]{1,3}x[1-9][0-9]{1,3}$ ]]; then
				res=$i && break
			fi
		done
		[ -n "$res" ] && break
	done
	[ -n "$res" ] && REPLY=$res && return

	# try abbreviations CIF, QCIF, ... delimited by "." or "_"
	for delim in _ .; do
		local IFS=$delim
		for i in $name; do
			case $i in # https://en.wikipedia.org/wiki/Common_Intermediate_Format
				 NTSC|ntsc) res=352x240;;   # 30 fps (11:9)  <=> SIF
				SQSIF|sqsif) res=128x96;;
				 QSIF|qsif)  res=176x120;;
			  	  SIF|sif)   res=352x240;;
				 2SIF|2sif)  res=704x240;;
				 4SIF|4sif)  res=704x480;;
				16SIF|16sif) res=1408x960;;

				  PAL|pal)   res=352x288;;   # 25 fps         <=> CIF
				SQCIF|sqcif) res=128x96;;
				 QCIF|qcif)  res=176x144;;
			 	  CIF|cif)   res=352x288;;
				 2CIF|2cif)  res=704x288;;   # Half D1
				 4CIF|4cif)  res=704x576;;   # D1
				16CIF|16cif) res=1408x1152;;

				720P|720p)   res=1280x720;;
			   1080P|1080p)  res=1920x1080;;
			   1440P|1440p)  res=2560x1440;;
			   2160P|2160p)  res=3840x2160;;
			   4320P|4320p)  res=7680x4320;;

			      2K|2k)     res=1920x1080;; # or 2560x1440
			      4K|4k)     res=3840x2160;;
			      8K|8k)     res=7680x4320;;
			esac
			[ -n "$res" ] && break
		done
		[ -n "$res" ] && break
	done
	[ -z "$res" ] && error_exit "can't detect resolution $filename"

	REPLY=$res
}

detect_framerate_string()
{	
	local filename=$1; shift
	local name=${filename//\\/}; name=${name##*[/\\]}; name=${name%%.*}
	local framerate=

	name=${name//FPS/fps}

	# try XXX pattern delimited by "." or "_"
	for delim in _ .; do
		local IFS=$delim
		for i in $name; do
			if [[ "$i" =~ ^[1-9][0-9]{0,2}(fps)?$ ]]; then
				framerate=${i%fps} && break
			fi
		done
		[ -n "$framerate" ] && break
	done
	[ -z "$framerate" ] && framerate=30

	REPLY=$framerate
}

detect_frame_num()
{
	local filename=$1; shift
	local res=${1:-};
	if [ -z "$res" ]; then
		detect_resolution_string "$filename" && res=$REPLY
	fi
	[ -z "$res" ] && return

	local numBytes=$(stat -c %s "$filename")
	[ -z "$numBytes" ] && return 1

	local width=${res%%x*}
	local height=${res##*x}
	local numFrames=$(( 2 * numBytes / width / height / 3 )) 
	local numBytes2=$(( 3 * numFrames * width * height / 2 ))
	[ $numBytes != $numBytes2 ] && error_exit "can't detect frames number $filename"

	REPLY=$numFrames
}
