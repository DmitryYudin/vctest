#
# For the sourcing
#
error_exit()
{
	local src="${BASH_SOURCE[1]}"; src=${src//\\//}; src=${src##*/}; src=${src%.*}
	printf "\n$src:${FUNCNAME[1]}():${BASH_LINENO[0]} error: %s\n" "$*" >&2 
	exit 1
}

# Always use '/' as separator
#
# Change nothing for non-Windows host. On Windows, replace Cygwin '/cygdrive/c'
# or Msys/Busybox '/c' prefix with the drive letter 'c:' to enable native apps
# to recognize the path name.
# Note, WSL buildins do not accept Windows path name in a form of 'C:/abcd'.
ospath() # ~= cygpath -m
{
	local path=$1; shift
	[[ -n "${WSL_DISTRO_NAME:-}" ]] && command wslpath -m "$path" && return
	case ${OS:-} in 
		*_NT) : ;;
		*) echo "$path" && return;;
	esac
	# msys, cygwin, busybox
	path=${path#/cygdrive} # cut prefix
	case $path in 
		/[a-zA-Z]/*) echo "${path:1:1}:${path:2}";;
		*) echo "$path";;
	esac
}
unixpath() # ~= cygpath -m
{
	command cygpath -m "$@"
}

relative_path()
{
	local file=$1
	local cwd=$(pwd -P)
	local path="$(cd "$(dirname "$file")"; pwd -P)/${file##*[/\\]}"
	case $path in $cwd/*) path=./${path#$cwd/}; esac
	REPLY=$path
}

dict_checkKey()
{
	local dict=$1 key=$2; val=${dict#*$key:};
	[[ "$val" == "$dict" ]] && return 1
	return 0
}
dict_getValue()
{
	local dict=$1 key=$2; val=${dict#*$key:};
	[[ "$val" == "$dict" ]] && error_exit "can't find key=$key"
	val=${val#"${val%%[! $'\t']*}"} # Remove leading whitespaces 
	val=${val%%[ $'\t']*} # Cut everything after left most whitespace
	REPLY=$val
}
dict_getValueEOL()
{
	local dict=$1 key=$2; val=${dict#*$key:};
	[[ "$val" == "$dict" ]] && error_exit "can't find key=$key"
	val=${val#"${val%%[! $'\t']*}"} # Remove leading whitespaces 
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
# Does not pretend to cover all use cases (non-printable characters, etc)
# We do not track actuall output position. Assume the printing starts from line start.
print_console()
{
	cut_to_console_width() {
		if [[ -z ${COLUMNS:-} ]]; then
			case ${OS:-} in *_NT) COLUMNS=$(mode.com 'con:' | grep -i Columns: | tr -d ' ' | cut -s -d':' -f2); esac
            [[ -z ${COLUMNS:-} ]] && command -v tput &>/dev/null && COLUMNS=$(tput cols)
            [[ -n ${COLUMNS:-} ]] && export COLUMNS
        fi

		# Note, Windows terminal inserts carriage character after printed string
		# this results in line break if len(str) == NUM_COLUMNS. So we cut to NUM_COLUMNS-1 length
		REPLY=$*
        # remove trailing spaces since we output to console
        REPLY=${REPLY%"${REPLY##*[! $'\t']}"}
        if [[ -n ${COLUMNS:-} && ${#REPLY} -ge ${COLUMNS:-} ]]; then
            # cut
            REPLY=${REPLY:0:$((COLUMNS - 6))}
            # remove spaces again
            REPLY=${REPLY%"${REPLY##*[! $'\t']}"}
            REPLY=$REPLY...
        fi
	}
    print_console_single_line() {        
        local str=$1 nl=$2
        # catch '\r' at the end and start of the line
        local cr_end=;   [[ ${str: -1} == $'\r' ]] && str=${str%$'\r'} && cr_end=1
        local cr_start=; [[ ${str:0:1} == $'\r' ]] && str=${str#$'\r'} && cr_start=1
    	cut_to_console_width "$str"; str=$REPLY
        # cleare entire line
        [[ -n $cr_start || -n ${GLOBAL_DO_LINE_CLEAR:-} ]] && str="\\x1B[2K\r$str"
        # append new line character
        [[ -n $nl ]] && str="$str\n"
        printf "$str" > /dev/tty
        # set LINE_CLEAR flag for the next line
        GLOBAL_DO_LINE_CLEAR=
        [[ -n $cr_end ]] && GLOBAL_DO_LINE_CLEAR=1
        return 0
    }
    local str nl_last=
    printf -v str "$@"
    [[ ${str: -1} == $'\n' ]] && nl_last=1

    # prepend with witespace since we do not want empty lines lost: '\n\n'
    str=${str//$'\n'/ $'\n'}
    # debug
    #str=${str//$'\r'/$'\n'}

    local IFS=$'\n'
    set -- $str
    for str do
        shift
        # remove added whitespace at the end of line
        str=${str% }
        local nl=1; [[ $# == 0 ]] && nl=$nl_last
        print_console_single_line "$str" "$nl"
    done

<< UT
    print_console "aaa\nbbb ccc\n"
    print_console "very long line                                                                 ends here\nshort line\n"
    print_console "\n\n"
    print_console "invisible\rpause, ending must be cleared on next line\r"
    sleep 1s
    print_console "ddd\n"
UT
}

# This also works for files, but we need dirs only
normalized_dirname() # TODO: alternatives if realpath does not exist
{
    local dirname=$1; shift
    # cd "$dirname" >/dev/null 2>&1 && pwd
    realpath $dirname 2>/dev/null
    # readlink -m "$dirname"
}

tempdir()
{
    case ${OS:-} in 
        *_NT) [[ -n "$TEMP" ]] && echo "$TEMP" || echo "$TMP";;
        *) echo ${TMPDIR:-/tmp};;
        #*) mkdir -p ${TMPDIR:-/tmp}/vctest && TMPDIR=${TMPDIR:-/tmp}/vctest mktemp -d;;
    esac
}

detect_resolution_string()
{	
	local filename=$1; shift
	local name=${filename//\\/}; name=${name##*[/\\]}; name=${name%%.*}
	local res=
    local oldIFS=$IFS

	# X -> x
	name=${name//X/x}

	# try WxH pattern delimited by "." or "_"
	for delim in _ .; do
		local IFS=$delim
		for i in $name; do
			if [[ "$i" =~ ^[1-9][0-9]{1,3}x[1-9][0-9]{1,3}$ ]]; then
				res=$i && break
			fi
		done
		[[ -n "$res" ]] && break
	done
	IFS=$oldIFS
	[[ -n "$res" ]] && REPLY=$res && return

	# try abbreviations CIF, QCIF, ... delimited by "." or "_"
	for delim in _ .; do
		local IFS=$delim
		for i in $name; do
			case $i in # https://en.wikipedia.org/wiki/Common_Intermediate_Format
				 NTSC|ntsc)   res=352x240;;   # 30 fps (11:9)  <=> SIF
				SQSIF|sqsif)  res=128x96;;
				 QSIF|qsif)   res=176x120;;
			  	  SIF|sif)    res=352x240;;
				 2SIF|2sif)   res=704x240;;
				 4SIF|4sif)   res=704x480;;
				16SIF|16sif)  res=1408x960;;

				  PAL|pal)    res=352x288;;   # 25 fps         <=> CIF
				SQCIF|sqcif)  res=128x96;;
				 QCIF|qcif)   res=176x144;;
			 	  CIF|cif)    res=352x288;;
				 2CIF|2cif)   res=704x288;;   # Half D1
				 4CIF|4cif)   res=704x576;;   # D1
				16CIF|16cif)  res=1408x1152;;

				360P*|360p*)  res=480x360;;
				480P*|480p*)  res=704x480;;
				720P*|720p*)  res=1280x720;;
			   1080P*|1080p*) res=1920x1080;;
			   1440P*|1440p*) res=2560x1440;;
			   2160P*|2160p*) res=3840x2160;;
			   4320P*|4320p*) res=7680x4320;;

			       2K|2k)     res=1920x1080;; # or 2560x1440
			       4K|4k)     res=3840x2160;;
			       8K|8k)     res=7680x4320;;
			esac
			[[ -n "$res" ]] && break
		done
	    IFS=$oldIFS		
		[[ -n "$res" ]] && break
	done
	[[ -n "$res" ]] && REPLY=$res && return

	# try W_H_FPS pattern
    local moviename=${name%%_[1-9]*}
    local patt=${name#$moviename}; patt=${patt#_}
	if [[ $patt =~ ^[1-9][0-9]{1,3}_[1-9][0-9]{1,3}_[1-9][0-9]{0,1}$ ]]; then
        local width=${patt%%_*}
        local height=${patt#*_}; height=${height%%_*}
		res=${width}x${height}
	fi
	[[ -n "$res" ]] && REPLY=$res && return

	[[ -z "$res" ]] && error_exit "can't detect resolution $filename"
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
		[[ -n "$framerate" ]] && break
	done
	[[ -z "$framerate" ]] && framerate=30

	REPLY=$framerate
}

detect_frame_num()
{
	local filename=$1; shift
	local res=${1:-};
	if [[ -z "$res" ]]; then
		detect_resolution_string "$filename" && res=$REPLY
	fi
	[[ -z "$res" ]] && return

	local numBytes=$(stat -c %s "$filename")
	[[ -z "$numBytes" ]] && return 1

	local width=${res%%x*}
	local height=${res##*x}
	local numFrames=$(( 2 * numBytes / width / height / 3 )) 
	local numBytes2=$(( 3 * numFrames * width * height / 2 ))
	[[ $numBytes != $numBytes2 ]] && error_exit "can't detect frames number $filename"

	REPLY=$numFrames
}
