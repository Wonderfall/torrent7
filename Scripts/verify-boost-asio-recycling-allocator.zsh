#!/bin/zsh
emulate -L zsh
setopt err_exit no_unset pipe_fail typeset_silent

fail() {
    print -ru2 -- "$1"
    exit 1
}

(( $# == 1 )) || fail "Usage: ${0:t} <arm64e Mach-O or static archive>"

typeset -r input=$1
[[ -f $input && ! -L $input ]] \
    || fail "Missing or unsafe binary input: $input"
typeset -r absolute_input=${input:A}

typeset -r lipo=$(/usr/bin/xcrun --find lipo)
typeset -r ar=$(/usr/bin/xcrun --find ar)
typeset temporary_directory
temporary_directory=$(/usr/bin/mktemp -d)
trap '/bin/rm -rf -- "$temporary_directory"' EXIT INT TERM

"$lipo" "$input" -verify_arch arm64e \
    || fail "Boost.Asio recycler verification requires arm64e code: $input"

# With typed-memory operations, the aligned-allocation descriptor is passed in
# x2. Bits 48...63 are the semantic layout summary; the lower bits identify the
# concrete allocation type. Check every linked call so a void-erasing wrapper
# cannot silently reappear, and require multiple concrete recycler classes.
record_disassembly() {
    /usr/bin/awk -v label="$1" '
    function clear_descriptor() {
        descriptor_valid = 0
        low = middle = flags = summary = "0"
    }

    function immediate(value) {
        gsub(/^#/, "", value)
        gsub(/,$/, "", value)
        return value
    }

    function nonzero(value) {
        return value !~ /^(0|0x0+)$/
    }

    BEGIN {
        clear_descriptor()
    }

    ($3 == "w2," || $3 == "x2,") && $2 != "movk" {
        clear_descriptor()
    }

    $2 == "mov" && ($3 == "w2," || $3 == "x2,") && $4 ~ /^#/ {
        low = immediate($4)
        descriptor_valid = 1
    }

    $2 == "movk" && ($3 == "w2," || $3 == "x2,") && $5 == "lsl" {
        value = immediate($4)
        shift = immediate($6)
        if (shift == "16") middle = value
        else if (shift == "32") flags = value
        else if (shift == "48") summary = value
    }

    $2 == "bl" && /_malloc_type_aligned_alloc/ {
        if (!descriptor_valid || !nonzero(summary))
            print "missing " label "@" $1
        else
            print "descriptor " low ":" middle ":" flags ":" summary \
                " " label "@" $1
        clear_descriptor()
    }
    '
}

verify_records() {
    /usr/bin/awk -v input="$input" '
    $1 == "missing" {
        ++calls
        ++missing_semantic_summary
        missing_sites = missing_sites "\n  " $2
    }

    $1 == "descriptor" {
        ++calls
        descriptors[$2] = 1
    }

    END {
        for (descriptor in descriptors)
            ++descriptor_count

        if (calls == 0) {
            print "No typed aligned-allocation calls found in " input \
                > "/dev/stderr"
            exit 1
        }
        if (missing_semantic_summary != 0) {
            print missing_semantic_summary " of " calls \
                " typed aligned-allocation calls lack a semantic type summary:" \
                missing_sites \
                > "/dev/stderr"
            exit 1
        }
        if (descriptor_count < 2) {
            print "Expected multiple concrete typed aligned-allocation classes; found " \
                descriptor_count > "/dev/stderr"
            exit 1
        }

        print "Verified " calls " typed aligned-allocation calls across " \
            descriptor_count " concrete descriptor classes"
    }
    ' "$1"
}

typeset -r records="$temporary_directory/descriptors.txt"
: >"$records"

if "$ar" -t "$input" >/dev/null 2>&1; then
    typeset -a members=()
    typeset member
    while IFS= read -r member; do
        [[ -n $member ]] || continue
        [[ $member == ${member:t} ]] \
            || fail "Unsafe archive member name: $member"
        members+=("$member")
    done < <(
        /usr/bin/xcrun nm -A -u "$input" \
            | /usr/bin/sed -n \
                's/.*:\([^:]*\): _malloc_type_aligned_alloc$/\1/p' \
            | /usr/bin/sort -u
    )
    (( ${#members[@]} > 0 )) \
        || fail "No archive members import typed aligned allocation: $input"

    (
        cd -- "$temporary_directory"
        "$ar" -x "$absolute_input" "${members[@]}"
    )
    typeset object
    typeset -a relocation_offsets=()
    typeset relocation_offset
    typeset -i call_address
    typeset -i start_address
    typeset -i stop_address
    for member in "${members[@]}"; do
        object="$temporary_directory/$member"
        [[ -f $object ]] \
            || fail "Missing extracted archive member: $member"
        relocation_offsets=()
        while IFS= read -r relocation_offset; do
            [[ -n $relocation_offset ]] || continue
            relocation_offsets+=("$relocation_offset")
        done < <(
            /usr/bin/xcrun llvm-objdump --macho --reloc "$object" \
                | /usr/bin/awk \
                    '$NF == "_malloc_type_aligned_alloc" { print $1 }'
        )
        (( ${#relocation_offsets[@]} > 0 )) \
            || fail "Missing typed aligned-allocation relocation: $member"

        for relocation_offset in "${relocation_offsets[@]}"; do
            call_address=$(( 0x$relocation_offset ))
            start_address=$(( call_address > 64 ? call_address - 64 : 0 ))
            stop_address=$(( call_address + 4 ))
            {
                /usr/bin/xcrun llvm-objdump \
                    --disassemble \
                    --no-show-raw-insn \
                    --start-address=$start_address \
                    --stop-address=$stop_address \
                    "$object"
                print -r -- "$relocation_offset: bl _malloc_type_aligned_alloc"
            } | record_disassembly "$member" >>"$records"
        done
    done
else
    /usr/bin/xcrun otool -tvV "$input" \
        | record_disassembly "${input:t}" >>"$records"
fi

verify_records "$records"
