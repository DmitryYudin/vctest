#
# Copyright © 2019 Dmitry Yudin. All rights reserved.
# Licensed under the Apache License, Version 2.0
#

if [[ "$(basename ${BASH_SOURCE-db.sh})" == "$(basename $0)" ]]; then

set -eu -o pipefail

usage()
{
	cat <<-\EOF
	Positional data base with a single primary key and a fixed number of
	data fields.

	DB stored in a file, one line per tuple with a whitespace separator.
	This script must be sourced into the user script. Typical usage as
	is the following:
	                              |  Pretty printf format for db file
	    . db.h                    |  Also, defines a number of fields.
	                              V
	    DB_init     db_file  "%1s %-5s %20s"
	    DB_add      $key
	    DB_remove   $key
	    DB_set_item $key $pos $value
	    DB_get_item $key $pos; value=$REPLY

	Command line frontend is available for the testing:

	    script [options]

	Options:
	    --help    - Print this help
	    --test    - Run built-in test

	EOF
}

entrypoint()
{
	[[ $# == 0 ]] && usage >&2 && return 1
	for arg do
		shift
		case "$arg" in
			-h|--help) usage; return;;
			-t|--test) ;;
			*) echo "error: unrecognized option arg";;
		esac
	done

	local url0=https://github.com/git-for-windows/git-sdk-32/tarball/master
	local url1=https://update.code.visualstudio.com/latest/win32-archive/insider
	local all_keys="$url0 $url1"
	local db_file="db_test.txt"
	rm -rf "$db_file"

	DB_init "$db_file" "%10s %8s %-50s"

	echo "Add keys..."
	for key in $all_keys; do
		DB_add $key || { echo "error: DB_add() failed '$key'" >&2 && return 1; }
	done
	echo "Verify keys..."
	for key in $all_keys; do
		! DB_add $key || { echo "error: DB_add() success on already added key '$key'" >&2 && return 1; }
	done
	echo "Verify key remove..."
	for key in $url1; do
		DB_remove $key || { echo "error: DB_remove() failed '$key'" >&2 && return 1; }
	done
	for key in $url1; do
		DB_add $key || { echo "error: DB_add() failed '$key'" >&2 && return 1; }
	done

	local pos
	echo "Writing data..."
	for key in $all_keys; do
		local val=${key: -5}
		for pos in 0 1 2; do
			DB_set_item $key $pos $val-$pos || echo "error: can't set item at position $pos" >&2
		done
	done
	echo "Rewriting data..."
	for key in $all_keys; do
		local val=${key: -7}
		for pos in 1 2; do
			DB_set_item $key $pos $val-$pos || echo "error: can't set item at position $pos" >&2
		done
	done
	echo "Verify data written..."
	for key in $all_keys; do
		local val=${key: -5}
		for pos in 0; do
			DB_get_item $key $pos || echo "error: can't get item at position $pos" >&2
			[[ "$val-$pos" == "$REPLY" ]] || "error: written '$val-$pos', but read '$REPLY' at position $pos" >&2
		done
	done
	echo "Verify data rewritten..."
	for key in $all_keys; do
		local val=${key: -7}
		for pos in 1 2; do
			DB_get_item $key $pos || echo "error: can't get item at position $pos" >&2
			[[ "$val-$pos" == "$REPLY" ]] || echo "error: written '$val-$pos', but read '$REPLY' at position $pos" >&2
		done
	done

    local keys
	DB_read_keys; keys=$REPLY
	if [[ "$all_keys" != "$keys" ]]; then
		echo "error: all_keys != DB_keys"
		for x in $all_keys; do echo "all_keys=$x"; done 
		for x in $keys; do echo "keys=$x"; done
	fi
	
	echo "Done"
#	rm -rf $db_file
}
fi

__DB_FILE=${1-db.txt}
__DB_FORMAT=${2-"%1s %8s %-50s"}
__DB_NODATA='-'
__DB_DATA=

DB_init()
{
	if [[ -n "${1:-}" ]]; then
		__DB_FILE=$1; shift
	fi
	if [[ -n "${1:-}" ]]; then
		__DB_FORMAT=$1; shift
	fi

	if [[ ! -e "$__DB_FILE" ]]; then
		touch "$__DB_FILE"
		return 0
	fi

	local i=0 line="" n N=$(echo "$__DB_FORMAT" | awk '{ printf NF }')
	N=$(( N + 1 )) # + key

	sed 's/#.*//' $__DB_FILE  | awk '{ printf NF"\n" }' |
		while read -r n; do # validate db
			i=$(( i + 1 ))
			[[ $n == 0 ]] && continue
			[[ $n == $N ]] && continue
			echo "error: wrong fileds number at line $i, must be $N, but $n items found" >&2
			return 1
		done

    __DB_DATA=$(cat "$__DB_FILE")
    if [[ "${__DB_DATA: -1}" != $'\n' ]]; then
        __DB_DATA="${__DB_DATA}"$'\n';
    fi
    __DB_DATA=${__DB_DATA//$'\r'/}
}

db_read_tuple()
{
    local key=$1; shift

    local IFS=$'\n'
    for line in $__DB_DATA; do
        case $line in *"$key") REPLY=$line; return; esac
    done
    REPLY=
}
db_read_keys()
{
    REPLY=

    local IFS=$'\n' line
    for line in $__DB_DATA; do
        REPLY="$REPLY ${line##* }"
    done
    REPLY=${REPLY# }
}
DB_read_keys()
{
    db_read_keys
    [[ -z "$REPLY" ]] && return 1
    return 0
}
DB_add()
{
	local key=$1; shift
	db_read_tuple "$key"
    if [[ -n "$REPLY" ]]; then # already present int db
        return 1
    fi

	local tuple= fmt
	for fmt in $__DB_FORMAT; do
		tuple="$tuple$(printf $fmt $__DB_NODATA) "
	done
    __DB_DATA="$__DB_DATA$tuple$key"$'\n'
    printf "%s" "$__DB_DATA" > $__DB_FILE
}
DB_remove()
{
	local key=$1; shift
	db_read_tuple "$key"
    [[ -z "$REPLY" ]] && return 1

    local IFS=$'\n' line data=
    for line in $__DB_DATA; do
        case $line in *"$key") continue; esac
		data="$data$line"$'\n'
	done
    __DB_DATA=$data
    printf "%s" "$__DB_DATA" > $__DB_FILE
}
db_replace_tuple()
{
	local key=$1; shift
	local tuple=$1; shift
#	sed -i'' "s,^.*$key$,$tuple," "$__DB_FILE"

    local IFS=$'\n' line data=
    for line in $__DB_DATA; do
		line="${line/*$key/$tuple}"
		data="$data$line"$'\n'
	done
    __DB_DATA=$data
    printf "%s" "$__DB_DATA" > $__DB_FILE
}

DB_set_item() # key pos value
{
	local key=$1; shift
	local pos=$1; shift
	local val=$1; shift

	local tuple=
	db_read_tuple "$key"; tuple=$REPLY;
	[[ -z "$tuple" ]] && return 1
	
	local i=0 item found=
	set --
	for item in $tuple; do
		if [[ $i == $pos ]]; then
			item=$val
			found=1
		fi
		set -- "$@" "$item"
		i=$(( i + 1 ))
	done
	[[ -z "$found" ]] && echo "error: can't set item at position '$pos'" >&2 && return 1

	local tuple=$(printf "$__DB_FORMAT %s" "$@")
	db_replace_tuple "$key" "$tuple"
}

DB_get_item() # key pos -> value
{
	local key=$1; shift
	local pos=$1; shift
	local tuple=
	db_read_tuple "$key"; tuple=$REPLY
    [[ -z "$tuple" ]] && echo "error: no tuple for key='$key'" >&2 && return 1

	local i=0 item;
	for item in $tuple; do
		if [[ $i == $pos ]]; then
			[[ "$item" == "$__DB_NODATA" ]] && return 1
			REPLY="$item"
			return
		fi
		i=$(( i + 1 ))
	done

	echo "error: no item at position $pos for key='$key'" >&2
	return 1
}

if [[ "$(basename ${BASH_SOURCE-db.sh})" == "$(basename $0)" ]]; then
	entrypoint "$@"
fi
