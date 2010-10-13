#!/bin/bash
#
# Copyright (c) 2005 Junio C Hamano
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see http://www.gnu.org/licenses/ .

# if --tee was passed, write the output not only to the terminal, but
# additionally to the file test-results/$BASENAME.out, too.
case "$GIT_TEST_TEE_STARTED, $* " in
done,*)
	# do not redirect again
	;;
*' --tee '*|*' --va'*)
	mkdir -p test-results
	BASE=test-results/$(basename "$0" .sh)
	(GIT_TEST_TEE_STARTED=done ${SHELL-sh} "$0" "$@" 2>&1;
	 echo $? > $BASE.exit) | tee $BASE.out
	test "$(cat $BASE.exit)" = 0
	exit
	;;
esac

# Keep the original TERM for say_color
ORIGINAL_TERM=$TERM

# For repeatability, reset the environment to known value.
LANG=C
LC_ALL=C
PAGER=cat
TZ=UTC
TERM=dumb
export LANG LC_ALL PAGER TERM TZ
GIT_TEST_CMP=${GIT_TEST_CMP:-diff -u}

# Protect ourselves from common misconfiguration to export
# CDPATH into the environment
unset CDPATH

unset GREP_OPTIONS

# Convenience
#
# A regexp to match 5 and 40 hexdigits
_x05='[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
_x40="$_x05$_x05$_x05$_x05$_x05$_x05$_x05$_x05"

_x04='[0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
_x32="$_x04$_x04$_x04$_x04$_x04$_x04$_x04$_x04"

# Each test should start with something like this, after copyright notices:
#
# test_description='Description of this test...
# This test checks if command xyzzy does the right thing...
# '
# . ./test-lib.sh
[ "x$ORIGINAL_TERM" != "xdumb" ] && (
		TERM=$ORIGINAL_TERM &&
		export TERM &&
		[ -t 1 ] &&
		tput bold >/dev/null 2>&1 &&
		tput setaf 1 >/dev/null 2>&1 &&
		tput sgr0 >/dev/null 2>&1
	) &&
	color=t

while test "$#" -ne 0
do
	case "$1" in
	-d|--d|--de|--deb|--debu|--debug)
		debug=t; shift ;;
	-i|--i|--im|--imm|--imme|--immed|--immedi|--immedia|--immediat|--immediate)
		immediate=t; shift ;;
	-l|--l|--lo|--lon|--long|--long-|--long-t|--long-te|--long-tes|--long-test|--long-tests)
		GIT_TEST_LONG=t; export GIT_TEST_LONG; shift ;;
	-h|--h|--he|--hel|--help)
		help=t; shift ;;
	-v|--v|--ve|--ver|--verb|--verbo|--verbos|--verbose)
		verbose=t; shift ;;
	-q|--q|--qu|--qui|--quie|--quiet)
		quiet=t; shift ;;
	--with-dashes)
		with_dashes=t; shift ;;
	--no-color)
		color=; shift ;;
	--no-python)
		# noop now...
		shift ;;
	--va|--val|--valg|--valgr|--valgri|--valgrin|--valgrind)
		valgrind=t; verbose=t; shift ;;
	--tee)
		shift ;; # was handled already
	--root=*)
		root=$(expr "z$1" : 'z[^=]*=\(.*\)')
		shift ;;
	*)
		echo "error: unknown test option '$1'" >&2; exit 1 ;;
	esac
done

if test -n "$color"; then
	say_color () {
		(
		TERM=$ORIGINAL_TERM
		export TERM
		case "$1" in
			error) tput bold; tput setaf 1;; # bold red
			skip)  tput bold; tput setaf 2;; # bold green
			pass)  tput setaf 2;;            # green
			info)  tput setaf 3;;            # brown
			*) test -n "$quiet" && return;;
		esac
		shift
		printf " "
                printf "$@"
		tput sgr0
		)
	}
else
	say_color() {
		test -z "$1" && test -n "$quiet" && return
		shift
		printf " "
                printf "$@"
	}
fi

error () {
	say_color error "error: $*"
	GIT_EXIT_OK=t
	exit 1
}

say () {
	say_color info "$*"
}

test "${test_description}" != "" ||
error "Test script did not set test_description."

if test "$help" = "t"
then
	echo "Tests ${test_description}"
	exit 0
fi

echo $(basename "$0"): "Testing ${test_description}"

exec 5>&1
if test "$verbose" = "t"
then
	exec 4>&2 3>&1
else
	exec 4>/dev/null 3>/dev/null
fi

test_failure=0
test_count=0
test_fixed=0
test_broken=0
test_success=0

die () {
	code=$?
	if test -n "$GIT_EXIT_OK"
	then
		exit $code
	else
		echo >&5 "FATAL: Unexpected exit with code $code"
		exit 1
	fi
}

GIT_EXIT_OK=
trap 'die' EXIT

test_decode_color () {
	sed	-e 's/.\[1m/<WHITE>/g' \
		-e 's/.\[31m/<RED>/g' \
		-e 's/.\[32m/<GREEN>/g' \
		-e 's/.\[33m/<YELLOW>/g' \
		-e 's/.\[34m/<BLUE>/g' \
		-e 's/.\[35m/<MAGENTA>/g' \
		-e 's/.\[36m/<CYAN>/g' \
		-e 's/.\[m/<RESET>/g'
}

q_to_nul () {
	perl -pe 'y/Q/\000/'
}

q_to_cr () {
	tr Q '\015'
}

append_cr () {
	sed -e 's/$/Q/' | tr Q '\015'
}

remove_cr () {
	tr '\015' Q | sed -e 's/Q$//'
}

# Notmuch helper functions
increment_mtime_amount=0
increment_mtime ()
{
    dir="$1"

    increment_mtime_amount=$((increment_mtime_amount + 1))
    touch -d "+${increment_mtime_amount} seconds" "$dir"
}

# Generate a new message in the mail directory, with a unique message
# ID and subject. The message is not added to the index.
#
# After this function returns, the filename of the generated message
# is available as $gen_msg_filename and the message ID is available as
# $gen_msg_id .
#
# This function supports named parameters with the bash syntax for
# assigning a value to an associative array ([name]=value). The
# supported parameters are:
#
#  [dir]=directory/of/choice
#
#	Generate the message in directory 'directory/of/choice' within
#	the mail store. The directory will be created if necessary.
#
#  [filename]=name
#
#	Store the message in file 'name'. The default is to store it
#	in 'msg-<count>', where <count> is three-digit number of the
#	message.
#	
#  [body]=text
#
#	Text to use as the body of the email message
#
#  '[from]="Some User <user@example.com>"'
#  '[to]="Some User <user@example.com>"'
#  '[subject]="Subject of email message"'
#  '[date]="RFC 822 Date"'
#
#	Values for email headers. If not provided, default values will
#	be generated instead.
#
#  '[cc]="Some User <user@example.com>"'
#  [reply-to]=some-address
#  [in-reply-to]=<message-id>
#  [references]=<message-id>
#  [content-type]=content-type-specification
#  '[header]=full header line, including keyword'
#
#	Additional values for email headers. If these are not provided
#	then the relevant headers will simply not appear in the
#	message.
#
#  '[id]=message-id'
#
#	Controls the message-id of the created message.
gen_msg_cnt=0
gen_msg_filename=""
gen_msg_id=""
generate_message ()
{
    # This is our (bash-specific) magic for doing named parameters
    local -A template="($@)"
    local additional_headers

    gen_msg_cnt=$((gen_msg_cnt + 1))
    if [ -z "${template[filename]}" ]; then
	gen_msg_name="msg-$(printf "%03d" $gen_msg_cnt)"
    else
	gen_msg_name=${template[filename]}
    fi

    if [ -z "${template[id]}" ]; then
	gen_msg_id="${gen_msg_name%:2,*}@notmuch-test-suite"
    else
	gen_msg_id="${template[id]}"
    fi

    if [ -z "${template[dir]}" ]; then
	gen_msg_filename="${MAIL_DIR}/$gen_msg_name"
    else
	gen_msg_filename="${MAIL_DIR}/${template[dir]}/$gen_msg_name"
	mkdir -p "$(dirname "$gen_msg_filename")"
    fi

    if [ -z "${template[body]}" ]; then
	template[body]="This is just a test message (#${gen_msg_cnt})"
    fi

    if [ -z "${template[from]}" ]; then
	template[from]="Notmuch Test Suite <test_suite@notmuchmail.org>"
    fi

    if [ -z "${template[to]}" ]; then
	template[to]="Notmuch Test Suite <test_suite@notmuchmail.org>"
    fi

    if [ -z "${template[subject]}" ]; then
	template[subject]="Test message #${gen_msg_cnt}"
    fi

    if [ -z "${template[date]}" ]; then
	template[date]="Tue, 05 Jan 2001 15:43:57 -0000"
    fi

    additional_headers=""
    if [ ! -z "${template[header]}" ]; then
	additional_headers="${template[header]}
${additional_headers}"
    fi

    if [ ! -z "${template[reply-to]}" ]; then
	additional_headers="Reply-To: ${template[reply-to]}
${additional_headers}"
    fi

    if [ ! -z "${template[in-reply-to]}" ]; then
	additional_headers="In-Reply-To: ${template[in-reply-to]}
${additional_headers}"
    fi

    if [ ! -z "${template[cc]}" ]; then
	additional_headers="Cc: ${template[cc]}
${additional_headers}"
    fi

    if [ ! -z "${template[references]}" ]; then
	additional_headers="References: ${template[references]}
${additional_headers}"
    fi

    if [ ! -z "${template[content-type]}" ]; then
	additional_headers="Content-Type: ${template[content-type]}
${additional_headers}"
    fi


cat <<EOF >"$gen_msg_filename"
From: ${template[from]}
To: ${template[to]}
Message-Id: <${gen_msg_id}>
Subject: ${template[subject]}
Date: ${template[date]}
${additional_headers}
${template[body]}
EOF

    # Ensure that the mtime of the containing directory is updated
    increment_mtime "$(dirname "${gen_msg_filename}")"
}

# Generate a new message and add it to the database.
#
# All of the arguments and return values supported by generate_message
# are also supported here, so see that function for details.
add_message ()
{
    generate_message "$@" &&
    notmuch new > /dev/null
}

# Generate a corpus of email and add it to the database.
#
# This corpus is fixed, (it happens to be 50 messages from early in
# the history of the notmuch mailing list), which allows for reliably
# testing commands that need to operate on a not-totally-trivial
# number of messages.
add_email_corpus ()
{
    rm -rf ${MAIL_DIR}
    if [ -d ../corpus.mail ]; then
	cp -a ../corpus.mail ${MAIL_DIR}
    else
	cp -a ../corpus ${MAIL_DIR}
	notmuch new
	cp -a ${MAIL_DIR} ../corpus.mail
    fi
}

test_begin_subtest ()
{
    test_subtest_name="$1"
}

# Pass test if two arguments match
#
# Note: Unlike all other test_expect_* functions, this function does
# not accept a test name. Instead, the caller should call
# test_begin_subtest before calling this function in order to set the
# name.
test_expect_equal ()
{
	test "$#" = 3 && { prereq=$1; shift; } || prereq=
	test "$#" = 2 ||
	error "bug in the test script: not 2 or 3 parameters to test_expect_equal"

	output="$1"
	expected="$2"
	if ! test_skip "$@"
	then
		if [ "$output" = "$expected" ]; then
			test_ok_ "$test_subtest_name"
		else
			testname=$this_test.$test_count
			echo "$expected" > $testname.expected
			echo "$output" > $testname.output
			test_failure_ "$test_subtest_name" "$(diff -u $testname.expected $testname.output)"
		fi
    fi
}

NOTMUCH_NEW ()
{
    notmuch new | grep -v -E -e '^Processed [0-9]*( total)? file|Found [0-9]* total file'
}

notmuch_search_sanitize ()
{
    sed -r -e 's/("?thread"?: ?)("?)................("?)/\1\2XXX\3/'
}

NOTMUCH_SHOW_FILENAME_SQUELCH='s,filename:.*/mail,filename:/XXX/mail,'
notmuch_show_sanitize ()
{
    sed -e "$NOTMUCH_SHOW_FILENAME_SQUELCH"
}

# End of notmuch helper functions

# Use test_set_prereq to tell that a particular prerequisite is available.
# The prerequisite can later be checked for in two ways:
#
# - Explicitly using test_have_prereq.
#
# - Implicitly by specifying the prerequisite tag in the calls to
#   test_expect_{success,failure,code}.
#
# The single parameter is the prerequisite tag (a simple word, in all
# capital letters by convention).

test_set_prereq () {
	satisfied="$satisfied$1 "
}
satisfied=" "

test_have_prereq () {
	case $satisfied in
	*" $1 "*)
		: yes, have it ;;
	*)
		! : nope ;;
	esac
}

# You are not expected to call test_ok_ and test_failure_ directly, use
# the text_expect_* functions instead.

test_ok_ () {
	test_success=$(($test_success + 1))
	say_color pass "%-6s" "PASS"
	echo " $@"
}

test_failure_ () {
	test_failure=$(($test_failure + 1))
	say_color error "%-6s" "FAIL"
	echo " $1"
	shift
	echo "$@" | sed -e 's/^/	/'
	test "$immediate" = "" || { GIT_EXIT_OK=t; exit 1; }
}

test_known_broken_ok_ () {
	test_fixed=$(($test_fixed+1))
	say_color pass "%-6s" "FIXED"
	echo " $@"
}

test_known_broken_failure_ () {
	test_broken=$(($test_broken+1))
	say_color pass "%-6s" "BROKEN"
	echo " $@"
}

test_debug () {
	test "$debug" = "" || eval "$1"
}

test_run_ () {
	test_cleanup=:
	eval >&3 2>&4 "$1"
	eval_ret=$?
	eval >&3 2>&4 "$test_cleanup"
	return 0
}

test_skip () {
	test_count=$(($test_count+1))
	to_skip=
	for skp in $NOTMUCH_SKIP_TESTS
	do
		case $this_test.$test_count in
		$skp)
			to_skip=t
		esac
	done
	if test -z "$to_skip" && test -n "$prereq" &&
	   ! test_have_prereq "$prereq"
	then
		to_skip=t
	fi
	case "$to_skip" in
	t)
		say_color skip >&3 "skipping test: $@"
		say_color skip "%-6s" "SKIP"
		echo " $1"
		: true
		;;
	*)
		false
		;;
	esac
}

test_expect_failure () {
	test "$#" = 3 && { prereq=$1; shift; } || prereq=
	test "$#" = 2 ||
	error "bug in the test script: not 2 or 3 parameters to test-expect-failure"
	if ! test_skip "$@"
	then
		test_run_ "$2"
		if [ "$?" = 0 -a "$eval_ret" = 0 ]
		then
			test_known_broken_ok_ "$1"
		else
			test_known_broken_failure_ "$1"
		fi
	fi
}

test_expect_success () {
	test "$#" = 3 && { prereq=$1; shift; } || prereq=
	test "$#" = 2 ||
	error "bug in the test script: not 2 or 3 parameters to test-expect-success"
	if ! test_skip "$@"
	then
		test_run_ "$2"
		if [ "$?" = 0 -a "$eval_ret" = 0 ]
		then
			test_ok_ "$1"
		else
			test_failure_ "$@"
		fi
	fi
}

test_expect_code () {
	test "$#" = 4 && { prereq=$1; shift; } || prereq=
	test "$#" = 3 ||
	error "bug in the test script: not 3 or 4 parameters to test-expect-code"
	if ! test_skip "$@"
	then
		test_run_ "$3"
		if [ "$?" = 0 -a "$eval_ret" = "$1" ]
		then
			test_ok_ "$2"
		else
			test_failure_ "$@"
		fi
	fi
}

# test_external runs external test scripts that provide continuous
# test output about their progress, and succeeds/fails on
# zero/non-zero exit code.  It outputs the test output on stdout even
# in non-verbose mode, and announces the external script with "* run
# <n>: ..." before running it.  When providing relative paths, keep in
# mind that all scripts run in "trash directory".
# Usage: test_external description command arguments...
# Example: test_external 'Perl API' perl ../path/to/test.pl
test_external () {
	test "$#" = 4 && { prereq=$1; shift; } || prereq=
	test "$#" = 3 ||
	error >&5 "bug in the test script: not 3 or 4 parameters to test_external"
	descr="$1"
	shift
	if ! test_skip "$descr" "$@"
	then
		# Announce the script to reduce confusion about the
		# test output that follows.
		say_color "" " run $test_count: $descr ($*)"
		# Run command; redirect its stderr to &4 as in
		# test_run_, but keep its stdout on our stdout even in
		# non-verbose mode.
		"$@" 2>&4
		if [ "$?" = 0 ]
		then
			test_ok_ "$descr"
		else
			test_failure_ "$descr" "$@"
		fi
	fi
}

# Like test_external, but in addition tests that the command generated
# no output on stderr.
test_external_without_stderr () {
	# The temporary file has no (and must have no) security
	# implications.
	tmp="$TMPDIR"; if [ -z "$tmp" ]; then tmp=/tmp; fi
	stderr="$tmp/git-external-stderr.$$.tmp"
	test_external "$@" 4> "$stderr"
	[ -f "$stderr" ] || error "Internal error: $stderr disappeared."
	descr="no stderr: $1"
	shift
	if [ ! -s "$stderr" ]; then
		rm "$stderr"
		test_ok_ "$descr"
	else
		if [ "$verbose" = t ]; then
			output=`echo; echo Stderr is:; cat "$stderr"`
		else
			output=
		fi
		# rm first in case test_failure exits.
		rm "$stderr"
		test_failure_ "$descr" "$@" "$output"
	fi
}

# This is not among top-level (test_expect_success | test_expect_failure)
# but is a prefix that can be used in the test script, like:
#
#	test_expect_success 'complain and die' '
#           do something &&
#           do something else &&
#	    test_must_fail git checkout ../outerspace
#	'
#
# Writing this as "! git checkout ../outerspace" is wrong, because
# the failure could be due to a segv.  We want a controlled failure.

test_must_fail () {
	"$@"
	test $? -gt 0 -a $? -le 129 -o $? -gt 192
}

# test_cmp is a helper function to compare actual and expected output.
# You can use it like:
#
#	test_expect_success 'foo works' '
#		echo expected >expected &&
#		foo >actual &&
#		test_cmp expected actual
#	'
#
# This could be written as either "cmp" or "diff -u", but:
# - cmp's output is not nearly as easy to read as diff -u
# - not all diff versions understand "-u"

test_cmp() {
	$GIT_TEST_CMP "$@"
}

# This function can be used to schedule some commands to be run
# unconditionally at the end of the test to restore sanity:
#
#	test_expect_success 'test core.capslock' '
#		git config core.capslock true &&
#		test_when_finished "git config --unset core.capslock" &&
#		hello world
#	'
#
# That would be roughly equivalent to
#
#	test_expect_success 'test core.capslock' '
#		git config core.capslock true &&
#		hello world
#		git config --unset core.capslock
#	'
#
# except that the greeting and config --unset must both succeed for
# the test to pass.

test_when_finished () {
	test_cleanup="{ $*
		} && (exit \"\$eval_ret\"); eval_ret=\$?; $test_cleanup"
}

test_done () {
	GIT_EXIT_OK=t
	test_results_dir="$TEST_DIRECTORY/test-results"
	mkdir -p "$test_results_dir"
	test_results_path="$test_results_dir/${0%.sh}-$$"

	echo "total $test_count" >> $test_results_path
	echo "success $test_success" >> $test_results_path
	echo "fixed $test_fixed" >> $test_results_path
	echo "broken $test_broken" >> $test_results_path
	echo "failed $test_failure" >> $test_results_path
	echo "" >> $test_results_path

	echo

	if [ "$test_failure" = "0" ]; then
	    rm -rf "$remove_tmp"
	    exit 0
	else
	    exit 1
	fi
}

find_notmuch_path ()
{
    dir="$1"

    while [ -n "$dir" ]; do
	bin="$dir/notmuch"
	if [ -x "$bin" ]; then
	    echo "$dir"
	    return
	fi
	dir="$(dirname "$dir")"
	if [ "$dir" = "/" ]; then
	    break
	fi
    done
}

# Test the binaries we have just built.  The tests are kept in
# test/ subdirectory and are run in 'trash directory' subdirectory.
TEST_DIRECTORY=$(pwd)
if test -n "$valgrind"
then
	make_symlink () {
		test -h "$2" &&
		test "$1" = "$(readlink "$2")" || {
			# be super paranoid
			if mkdir "$2".lock
			then
				rm -f "$2" &&
				ln -s "$1" "$2" &&
				rm -r "$2".lock
			else
				while test -d "$2".lock
				do
					say "Waiting for lock on $2."
					sleep 1
				done
			fi
		}
	}

	make_valgrind_symlink () {
		# handle only executables
		test -x "$1" || return

		base=$(basename "$1")
		symlink_target=$TEST_DIRECTORY/../$base
		# do not override scripts
		if test -x "$symlink_target" &&
		    test ! -d "$symlink_target" &&
		    test "#!" != "$(head -c 2 < "$symlink_target")"
		then
			symlink_target=../valgrind.sh
		fi
		case "$base" in
		*.sh|*.perl)
			symlink_target=../unprocessed-script
		esac
		# create the link, or replace it if it is out of date
		make_symlink "$symlink_target" "$GIT_VALGRIND/bin/$base" || exit
	}

	# override notmuch executable in TEST_DIRECTORY/..
	GIT_VALGRIND=$TEST_DIRECTORY/valgrind
	mkdir -p "$GIT_VALGRIND"/bin
	make_valgrind_symlink $TEST_DIRECTORY/../notmuch
	OLDIFS=$IFS
	IFS=:
	for path in $PATH
	do
		ls "$path"/notmuch 2> /dev/null |
		while read file
		do
			make_valgrind_symlink "$file"
		done
	done
	IFS=$OLDIFS
	PATH=$GIT_VALGRIND/bin:$PATH
	GIT_EXEC_PATH=$GIT_VALGRIND/bin
	export GIT_VALGRIND
else # normal case
	notmuch_path=`find_notmuch_path "$TEST_DIRECTORY"`
	test -n "$notmuch_path" && PATH="$notmuch_path:$PATH"
fi
export PATH

# Test repository
test="tmp.$(basename "$0" .sh)"
test -n "$root" && test="$root/$test"
case "$test" in
/*) TMP_DIRECTORY="$test" ;;
 *) TMP_DIRECTORY="$TEST_DIRECTORY/$test" ;;
esac
test ! -z "$debug" || remove_tmp=$TMP_DIRECTORY
rm -fr "$test" || {
	GIT_EXIT_OK=t
	echo >&5 "FATAL: Cannot prepare test area"
	exit 1
}

MAIL_DIR="${TMP_DIRECTORY}/mail"
export NOTMUCH_CONFIG="${TMP_DIRECTORY}/notmuch-config"

mkdir -p "${test}"
mkdir -p "${MAIL_DIR}"

cat <<EOF >"${NOTMUCH_CONFIG}"
[database]
path=${MAIL_DIR}

[user]
name=Notmuch Test Suite
primary_email=test_suite@notmuchmail.org
other_email=test_suite_other@notmuchmail.org;test_suite@otherdomain.org
EOF


# Use -P to resolve symlinks in our working directory so that the cwd
# in subprocesses like git equals our $PWD (for pathname comparisons).
cd -P "$test" || error "Cannot setup test environment"

this_test=${0##*/}
this_test=${this_test%%-*}
for skp in $NOTMUCH_SKIP_TESTS
do
	to_skip=
	for skp in $NOTMUCH_SKIP_TESTS
	do
		case "$this_test" in
		$skp)
			to_skip=t
		esac
	done
	case "$to_skip" in
	t)
		say_color skip >&3 "skipping test $this_test altogether"
		say_color skip "skip all tests in $this_test"
		test_done
	esac
done

# Provide an implementation of the 'yes' utility
yes () {
	if test $# = 0
	then
		y=y
	else
		y="$*"
	fi

	while echo "$y"
	do
		:
	done
}

# Fix some commands on Windows
case $(uname -s) in
*MINGW*)
	# Windows has its own (incompatible) sort and find
	sort () {
		/usr/bin/sort "$@"
	}
	find () {
		/usr/bin/find "$@"
	}
	sum () {
		md5sum "$@"
	}
	# git sees Windows-style pwd
	pwd () {
		builtin pwd -W
	}
	# no POSIX permissions
	# backslashes in pathspec are converted to '/'
	# exec does not inherit the PID
	;;
*)
	test_set_prereq POSIXPERM
	test_set_prereq BSLASHPSPEC
	test_set_prereq EXECKEEPSPID
	;;
esac

test -z "$NO_PERL" && test_set_prereq PERL
test -z "$NO_PYTHON" && test_set_prereq PYTHON

# test whether the filesystem supports symbolic links
ln -s x y 2>/dev/null && test -h y 2>/dev/null && test_set_prereq SYMLINKS
rm -f y
